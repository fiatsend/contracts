// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {P2PExchange} from "../src/payments/P2PExchange.sol";
import {IP2PExchange} from "../src/interfaces/IP2PExchange.sol";
import {GHSFIAT} from "../src/tokens/GHSFIAT.sol";

/// @title P2PExchangeTest
/// @notice Tests for the P2PExchange order lifecycle and dispute resolution.
contract P2PExchangeTest is Test {
    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------

    P2PExchange public exchange;
    GHSFIAT public token; // mock stablecoin

    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------

    address public owner = makeAddr("owner");
    address public resolver = makeAddr("resolver");
    address public maker = makeAddr("maker");
    address public taker = makeAddr("taker");
    address public attacker = makeAddr("attacker");

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant AMOUNT = 500 * 10 ** 18;
    uint256 public constant EXPIRY_DURATION = 24 hours;
    string public constant REFERENCE = "BNP2P-ORDER-XY7890";
    string public constant PLATFORM = "binance";

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.startPrank(owner);
        token = new GHSFIAT(owner);
        token.grantRole(token.MINTER_ROLE(), owner);
        token.mint(maker, 10_000 * 10 ** 18);
        token.mint(taker, 10_000 * 10 ** 18);
        exchange = new P2PExchange(resolver);
        vm.stopPrank();

        // Maker pre-approves exchange
        vm.prank(maker);
        token.approve(address(exchange), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Helper
    // -------------------------------------------------------------------------

    function _orderId(string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(label));
    }

    function _createOrder(bytes32 orderId) internal {
        vm.prank(maker);
        exchange.createOrder(orderId, address(token), AMOUNT, REFERENCE, PLATFORM, EXPIRY_DURATION);
    }

    // -------------------------------------------------------------------------
    // createOrder
    // -------------------------------------------------------------------------

    function test_CreateOrder_Success() public {
        bytes32 oid = _orderId("o1");

        vm.expectEmit(true, true, false, true);
        emit IP2PExchange.OrderCreated(oid, maker, address(token), AMOUNT, REFERENCE, PLATFORM);

        _createOrder(oid);

        IP2PExchange.P2POrder memory o = exchange.getOrder(oid);
        assertEq(o.maker, maker);
        assertEq(o.token, address(token));
        assertEq(o.amount, AMOUNT);
        assertEq(o.paymentReference, REFERENCE);
        assertEq(o.exchangePlatform, PLATFORM);
        assertEq(uint8(o.status), uint8(IP2PExchange.OrderStatus.Open));
        assertEq(token.balanceOf(address(exchange)), AMOUNT);
    }

    function test_CreateOrder_RevertDuplicateId() public {
        bytes32 oid = _orderId("o2");
        _createOrder(oid);

        vm.prank(maker);
        vm.expectRevert(P2PExchange.OrderAlreadyExists.selector);
        exchange.createOrder(oid, address(token), AMOUNT, REFERENCE, PLATFORM, EXPIRY_DURATION);
    }

    function test_CreateOrder_RevertZeroAmount() public {
        vm.prank(maker);
        vm.expectRevert(P2PExchange.ZeroAmount.selector);
        exchange.createOrder(_orderId("o3"), address(token), 0, REFERENCE, PLATFORM, EXPIRY_DURATION);
    }

    function test_CreateOrder_RevertZeroExpiryDuration() public {
        vm.prank(maker);
        vm.expectRevert(P2PExchange.ZeroExpiryDuration.selector);
        exchange.createOrder(_orderId("o4"), address(token), AMOUNT, REFERENCE, PLATFORM, 0);
    }

    function test_CreateOrder_AppearsInOpenOrders() public {
        bytes32 oid = _orderId("o5");
        _createOrder(oid);

        bytes32[] memory open = exchange.getOpenOrders(0);
        assertEq(open.length, 1);
        assertEq(open[0], oid);
    }

    function test_CreateOrder_AppearsInUserOrders() public {
        bytes32 oid = _orderId("o6");
        _createOrder(oid);

        bytes32[] memory orders = exchange.getUserOrders(maker);
        assertEq(orders.length, 1);
        assertEq(orders[0], oid);
    }

    // -------------------------------------------------------------------------
    // takeOrder
    // -------------------------------------------------------------------------

    function test_TakeOrder_Success() public {
        bytes32 oid = _orderId("t1");
        _createOrder(oid);

        vm.expectEmit(true, true, false, false);
        emit IP2PExchange.OrderTaken(oid, taker);

        vm.prank(taker);
        exchange.takeOrder(oid);

        IP2PExchange.P2POrder memory o = exchange.getOrder(oid);
        assertEq(o.taker, taker);
        assertEq(uint8(o.status), uint8(IP2PExchange.OrderStatus.Locked));
        assertGt(o.lockedAt, 0);
    }

    function test_TakeOrder_RemovedFromOpenOrders() public {
        bytes32 oid = _orderId("t2");
        _createOrder(oid);

        vm.prank(taker);
        exchange.takeOrder(oid);

        bytes32[] memory open = exchange.getOpenOrders(0);
        assertEq(open.length, 0);
    }

    function test_TakeOrder_AppearsInTakerUserOrders() public {
        bytes32 oid = _orderId("t3");
        _createOrder(oid);

        vm.prank(taker);
        exchange.takeOrder(oid);

        bytes32[] memory takerOrders = exchange.getUserOrders(taker);
        assertEq(takerOrders.length, 1);
        assertEq(takerOrders[0], oid);
    }

    function test_TakeOrder_RevertSelfTake() public {
        bytes32 oid = _orderId("t4");
        _createOrder(oid);

        vm.prank(maker);
        vm.expectRevert(P2PExchange.SelfTake.selector);
        exchange.takeOrder(oid);
    }

    function test_TakeOrder_RevertNotOpen() public {
        bytes32 oid = _orderId("t5");
        _createOrder(oid);

        vm.prank(taker);
        exchange.takeOrder(oid); // first take — succeeds

        vm.prank(attacker);
        vm.expectRevert(P2PExchange.OrderNotOpen.selector);
        exchange.takeOrder(oid); // second take — fails
    }

    // -------------------------------------------------------------------------
    // confirmPayment
    // -------------------------------------------------------------------------

    function test_ConfirmPayment_Success() public {
        bytes32 oid = _orderId("cp1");
        _createOrder(oid);

        vm.prank(taker);
        exchange.takeOrder(oid);

        uint256 takerBefore = token.balanceOf(taker);

        vm.expectEmit(true, true, false, true);
        emit IP2PExchange.OrderCompleted(oid, taker, AMOUNT);

        vm.prank(maker);
        exchange.confirmPayment(oid);

        assertEq(token.balanceOf(taker), takerBefore + AMOUNT);
        assertEq(uint8(exchange.getOrder(oid).status), uint8(IP2PExchange.OrderStatus.Completed));
        assertGt(exchange.getOrder(oid).completedAt, 0);
    }

    function test_ConfirmPayment_RevertNotMaker() public {
        bytes32 oid = _orderId("cp2");
        _createOrder(oid);
        vm.prank(taker);
        exchange.takeOrder(oid);

        vm.prank(taker); // taker cannot confirm
        vm.expectRevert(P2PExchange.NotMaker.selector);
        exchange.confirmPayment(oid);
    }

    function test_ConfirmPayment_RevertNotLocked() public {
        bytes32 oid = _orderId("cp3");
        _createOrder(oid);

        vm.prank(maker);
        vm.expectRevert(P2PExchange.OrderNotLocked.selector);
        exchange.confirmPayment(oid);
    }

    // -------------------------------------------------------------------------
    // cancelOrder
    // -------------------------------------------------------------------------

    function test_CancelOrder_Success() public {
        bytes32 oid = _orderId("ca1");
        _createOrder(oid);

        uint256 makerBefore = token.balanceOf(maker);

        vm.expectEmit(true, false, false, false);
        emit IP2PExchange.OrderCancelled(oid);

        vm.prank(maker);
        exchange.cancelOrder(oid);

        assertEq(token.balanceOf(maker), makerBefore + AMOUNT);
        assertEq(uint8(exchange.getOrder(oid).status), uint8(IP2PExchange.OrderStatus.Cancelled));
    }

    function test_CancelOrder_RemovedFromOpenOrders() public {
        bytes32 oid = _orderId("ca2");
        _createOrder(oid);
        vm.prank(maker);
        exchange.cancelOrder(oid);

        assertEq(exchange.getOpenOrders(0).length, 0);
    }

    function test_CancelOrder_RevertNotMaker() public {
        bytes32 oid = _orderId("ca3");
        _createOrder(oid);

        vm.prank(attacker);
        vm.expectRevert(P2PExchange.NotMaker.selector);
        exchange.cancelOrder(oid);
    }

    function test_CancelOrder_RevertAlreadyTaken() public {
        bytes32 oid = _orderId("ca4");
        _createOrder(oid);
        vm.prank(taker);
        exchange.takeOrder(oid);

        vm.prank(maker);
        vm.expectRevert(P2PExchange.OrderNotOpen.selector);
        exchange.cancelOrder(oid);
    }

    // -------------------------------------------------------------------------
    // disputeOrder
    // -------------------------------------------------------------------------

    function test_DisputeOrder_ByMaker() public {
        bytes32 oid = _orderId("d1");
        _createOrder(oid);
        vm.prank(taker);
        exchange.takeOrder(oid);

        vm.expectEmit(true, true, false, false);
        emit IP2PExchange.OrderDisputed(oid, maker);

        vm.prank(maker);
        exchange.disputeOrder(oid);

        assertEq(uint8(exchange.getOrder(oid).status), uint8(IP2PExchange.OrderStatus.Disputed));
    }

    function test_DisputeOrder_ByTaker() public {
        bytes32 oid = _orderId("d2");
        _createOrder(oid);
        vm.prank(taker);
        exchange.takeOrder(oid);

        vm.prank(taker);
        exchange.disputeOrder(oid);

        assertEq(uint8(exchange.getOrder(oid).status), uint8(IP2PExchange.OrderStatus.Disputed));
    }

    function test_DisputeOrder_RevertNotParty() public {
        bytes32 oid = _orderId("d3");
        _createOrder(oid);
        vm.prank(taker);
        exchange.takeOrder(oid);

        vm.prank(attacker);
        vm.expectRevert(P2PExchange.NotParty.selector);
        exchange.disputeOrder(oid);
    }

    function test_DisputeOrder_RevertNotLocked() public {
        bytes32 oid = _orderId("d4");
        _createOrder(oid);

        vm.prank(maker);
        vm.expectRevert(P2PExchange.OrderNotLocked.selector);
        exchange.disputeOrder(oid);
    }

    // -------------------------------------------------------------------------
    // resolveDispute
    // -------------------------------------------------------------------------

    function test_ResolveDispute_WinnerIsMaker() public {
        bytes32 oid = _orderId("res1");
        _createOrder(oid);
        vm.prank(taker);
        exchange.takeOrder(oid);
        vm.prank(maker);
        exchange.disputeOrder(oid);

        uint256 makerBefore = token.balanceOf(maker);

        vm.expectEmit(true, true, false, true);
        emit IP2PExchange.DisputeResolved(oid, maker, AMOUNT);

        vm.prank(resolver);
        exchange.resolveDispute(oid, maker);

        assertEq(token.balanceOf(maker), makerBefore + AMOUNT);
        assertEq(uint8(exchange.getOrder(oid).status), uint8(IP2PExchange.OrderStatus.Completed));
    }

    function test_ResolveDispute_WinnerIsTaker() public {
        bytes32 oid = _orderId("res2");
        _createOrder(oid);
        vm.prank(taker);
        exchange.takeOrder(oid);
        vm.prank(taker);
        exchange.disputeOrder(oid);

        uint256 takerBefore = token.balanceOf(taker);

        vm.prank(resolver);
        exchange.resolveDispute(oid, taker);

        assertEq(token.balanceOf(taker), takerBefore + AMOUNT);
    }

    function test_ResolveDispute_RevertNotResolver() public {
        bytes32 oid = _orderId("res3");
        _createOrder(oid);
        vm.prank(taker);
        exchange.takeOrder(oid);
        vm.prank(maker);
        exchange.disputeOrder(oid);

        vm.prank(attacker);
        vm.expectRevert(P2PExchange.NotDisputeResolver.selector);
        exchange.resolveDispute(oid, maker);
    }

    function test_ResolveDispute_RevertInvalidWinner() public {
        bytes32 oid = _orderId("res4");
        _createOrder(oid);
        vm.prank(taker);
        exchange.takeOrder(oid);
        vm.prank(maker);
        exchange.disputeOrder(oid);

        vm.prank(resolver);
        vm.expectRevert(P2PExchange.InvalidWinner.selector);
        exchange.resolveDispute(oid, attacker); // attacker is not maker or taker
    }

    function test_ResolveDispute_RevertNotDisputed() public {
        bytes32 oid = _orderId("res5");
        _createOrder(oid);
        vm.prank(taker);
        exchange.takeOrder(oid);

        vm.prank(resolver);
        vm.expectRevert(P2PExchange.OrderNotDisputed.selector);
        exchange.resolveDispute(oid, maker); // status is Locked, not Disputed
    }

    // -------------------------------------------------------------------------
    // getOpenOrders
    // -------------------------------------------------------------------------

    function test_GetOpenOrders_LimitRespected() public {
        for (uint256 i; i < 5; ++i) {
            bytes32 oid = _orderId(string(abi.encodePacked("open", i)));
            vm.prank(maker);
            exchange.createOrder(oid, address(token), 10 * 10 ** 18, REFERENCE, PLATFORM, EXPIRY_DURATION);
        }

        bytes32[] memory limited = exchange.getOpenOrders(3);
        assertEq(limited.length, 3);

        bytes32[] memory all = exchange.getOpenOrders(0);
        assertEq(all.length, 5);
    }

    // -------------------------------------------------------------------------
    // Pause / unpause
    // -------------------------------------------------------------------------

    function test_Pause_BlocksCreateOrder() public {
        vm.prank(owner);
        exchange.pause();

        vm.prank(maker);
        vm.expectRevert();
        exchange.createOrder(_orderId("p1"), address(token), AMOUNT, REFERENCE, PLATFORM, EXPIRY_DURATION);
    }

    function test_Pause_BlocksTakeOrder() public {
        bytes32 oid = _orderId("p2");
        _createOrder(oid);

        vm.prank(owner);
        exchange.pause();

        vm.prank(taker);
        vm.expectRevert();
        exchange.takeOrder(oid);
    }

    function test_Unpause_RestoresCreateOrder() public {
        vm.prank(owner);
        exchange.pause();
        vm.prank(owner);
        exchange.unpause();

        _createOrder(_orderId("p3")); // should succeed
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function test_SetDisputeResolver_OnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        exchange.setDisputeResolver(attacker);
    }

    function test_SetDisputeResolver_UpdatesCorrectly() public {
        address newResolver = makeAddr("newResolver");
        vm.prank(owner);
        exchange.setDisputeResolver(newResolver);
        assertEq(exchange.disputeResolver(), newResolver);
    }
}
