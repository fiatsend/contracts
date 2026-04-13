// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/payments/PaymentRouter.sol";
import {MobileNumberNFT} from "../src/identity/MobileNumberNFT.sol";
import {GHSFIAT} from "../src/tokens/GHSFIAT.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";

contract PaymentRouterTest is Test {
    PaymentRouter public router;
    MobileNumberNFT public mobileNFT;
    GHSFIAT public token;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant AMOUNT = 50 * 10 ** 18;

    bytes public alicePhone = bytes("alice_encrypted_phone");
    bytes public bobPhone = bytes("bob_encrypted_phone");

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.startPrank(owner);

        token = new GHSFIAT(owner);
        mobileNFT = new MobileNumberNFT("https://api.fiatsend.com/identity/");
        router = new PaymentRouter(address(mobileNFT), treasury);

        token.grantRole(token.MINTER_ROLE(), owner);
        token.mint(alice, 1000 * 10 ** 18);
        token.mint(bob, 1000 * 10 ** 18);

        vm.stopPrank();

        vm.prank(alice);
        mobileNFT.registerMobile(alicePhone, "GH");

        vm.prank(bob);
        mobileNFT.registerMobile(bobPhone, "GH");

        vm.prank(alice);
        token.approve(address(router), type(uint256).max);

        vm.prank(bob);
        token.approve(address(router), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Deployment
    // -------------------------------------------------------------------------

    function test_Deployment() public view {
        assertEq(address(router.mobileNumberNFT()), address(mobileNFT));
        assertEq(router.feeTreasury(), treasury);
        assertEq(router.p2pFeeRate(), 0);
        assertEq(router.owner(), owner);
    }

    // -------------------------------------------------------------------------
    // Send
    // -------------------------------------------------------------------------

    function test_Send_Success() public {
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        router.send(address(token), bob, AMOUNT, "lunch money");

        assertEq(token.balanceOf(bob), bobBefore + AMOUNT);
        assertEq(token.balanceOf(alice), 1000 * 10 ** 18 - AMOUNT);
    }

    function test_Send_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IPaymentRouter.PaymentSent(alice, bob, address(token), AMOUNT, "hello");

        vm.prank(alice);
        router.send(address(token), bob, AMOUNT, "hello");
    }

    function test_Send_RevertZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(PaymentRouter.ZeroAddress.selector);
        router.send(address(token), address(0), AMOUNT, "");
    }

    function test_Send_RevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(PaymentRouter.ZeroAmount.selector);
        router.send(address(token), bob, 0, "");
    }

    function test_Send_RevertSelfPayment() public {
        vm.prank(alice);
        vm.expectRevert(PaymentRouter.SelfPayment.selector);
        router.send(address(token), alice, AMOUNT, "");
    }

    // -------------------------------------------------------------------------
    // Send with fee
    // -------------------------------------------------------------------------

    function test_Send_WithFee() public {
        vm.prank(owner);
        router.setP2PFeeRate(100); // 1%

        uint256 fee = (AMOUNT * 100) / 10_000;
        uint256 netAmount = AMOUNT - fee;

        uint256 bobBefore = token.balanceOf(bob);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(alice);
        router.send(address(token), bob, AMOUNT, "");

        assertEq(token.balanceOf(bob), bobBefore + netAmount);
        assertEq(token.balanceOf(treasury), treasuryBefore + fee);
    }

    // -------------------------------------------------------------------------
    // Send to phone
    // -------------------------------------------------------------------------

    function test_SendToPhone_Success() public {
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        router.sendToPhone(address(token), bobPhone, AMOUNT, "via phone");

        assertEq(token.balanceOf(bob), bobBefore + AMOUNT);
    }

    function test_SendToPhone_RevertPhoneNotRegistered() public {
        vm.prank(alice);
        vm.expectRevert(PaymentRouter.PhoneNotRegistered.selector);
        router.sendToPhone(address(token), bytes("nonexistent_phone"), AMOUNT, "");
    }

    // -------------------------------------------------------------------------
    // Payment requests
    // -------------------------------------------------------------------------

    function test_CreatePaymentRequest() public {
        vm.prank(alice);
        uint256 reqId = router.createPaymentRequest(address(token), bob, AMOUNT, "pay me back");

        assertEq(reqId, 1);
        IPaymentRouter.PaymentRequest memory req = router.getPaymentRequest(reqId);
        assertEq(req.from, alice);
        assertEq(req.to, bob);
        assertEq(req.amount, AMOUNT);
        assertEq(uint8(req.status), uint8(IPaymentRouter.RequestStatus.Pending));
    }

    function test_PayRequest_Success() public {
        vm.prank(alice);
        uint256 reqId = router.createPaymentRequest(address(token), bob, AMOUNT, "pay me");

        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(bob);
        router.payRequest(reqId);

        IPaymentRouter.PaymentRequest memory req = router.getPaymentRequest(reqId);
        assertEq(uint8(req.status), uint8(IPaymentRouter.RequestStatus.Paid));
        assertEq(token.balanceOf(alice), aliceBefore + AMOUNT);
    }

    function test_PayRequest_RevertWrongPayer() public {
        address charlie = makeAddr("charlie");
        vm.prank(alice);
        uint256 reqId = router.createPaymentRequest(address(token), bob, AMOUNT, "pay me");

        vm.prank(charlie);
        vm.expectRevert(PaymentRouter.NotRequestRecipient.selector);
        router.payRequest(reqId);
    }

    function test_PayRequest_RevertAlreadyPaid() public {
        vm.prank(alice);
        uint256 reqId = router.createPaymentRequest(address(token), bob, AMOUNT, "pay me");

        vm.prank(bob);
        router.payRequest(reqId);

        vm.prank(bob);
        vm.expectRevert(PaymentRouter.RequestNotPending.selector);
        router.payRequest(reqId);
    }

    function test_CancelRequest_Success() public {
        vm.prank(alice);
        uint256 reqId = router.createPaymentRequest(address(token), bob, AMOUNT, "pay me");

        vm.prank(alice);
        router.cancelRequest(reqId);

        IPaymentRouter.PaymentRequest memory req = router.getPaymentRequest(reqId);
        assertEq(uint8(req.status), uint8(IPaymentRouter.RequestStatus.Cancelled));
    }

    function test_CancelRequest_RevertNonOwner() public {
        vm.prank(alice);
        uint256 reqId = router.createPaymentRequest(address(token), bob, AMOUNT, "pay me");

        vm.prank(bob);
        vm.expectRevert(PaymentRouter.NotRequestOwner.selector);
        router.cancelRequest(reqId);
    }

    function test_GetPaymentRequest_RevertNotFound() public {
        vm.expectRevert(PaymentRouter.RequestNotFound.selector);
        router.getPaymentRequest(999);
    }
}
