// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PayoutEscrow} from "../src/payments/PayoutEscrow.sol";
import {IPayoutEscrow} from "../src/interfaces/IPayoutEscrow.sol";
import {FiatsendGateway} from "../src/payments/FiatsendGateway.sol";
import {MobileNumberNFT} from "../src/identity/MobileNumberNFT.sol";
import {Withdrawals} from "../src/payments/Withdrawals.sol";
import {GHSFIAT} from "../src/tokens/GHSFIAT.sol";

/// @title PayoutEscrowTest
/// @notice Tests for the PayoutEscrow B2B payout contract.
contract PayoutEscrowTest is Test {
    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------

    PayoutEscrow public escrow;
    FiatsendGateway public gateway;
    MobileNumberNFT public mobileNFT;
    Withdrawals public withdrawals;
    GHSFIAT public usdc; // repurposed GHSFIAT as a mock stablecoin

    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public business = makeAddr("business"); // authorized B2B sender
    address public recipient = makeAddr("recipient");
    address public recipient2 = makeAddr("recipient2");
    address public attacker = makeAddr("attacker");

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant AMOUNT = 100 * 10 ** 18;
    uint256 public constant EXPIRY = 30 days;
    bytes public constant PHONE_BYTES = bytes("GH+233244000000");
    bytes public constant PHONE2_BYTES = bytes("GH+233244000001");
    bytes32 public phoneHash;
    bytes32 public phone2Hash;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.startPrank(owner);

        // Deploy stablecoin
        usdc = new GHSFIAT(owner);
        usdc.grantRole(usdc.MINTER_ROLE(), owner);
        usdc.mint(business, 10_000 * 10 ** 18);

        // Deploy MobileNumberNFT
        mobileNFT = new MobileNumberNFT("https://api.fiatsend.com/identity/");

        // Deploy Withdrawals
        withdrawals = new Withdrawals();

        // Deploy Gateway
        FiatsendGateway gatewayImpl = new FiatsendGateway();
        bytes memory initData = abi.encodeWithSelector(
            FiatsendGateway.initialize.selector, address(usdc), address(mobileNFT), treasury, 50
        );
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), initData);
        gateway = FiatsendGateway(address(gatewayProxy));

        // Wire gateway
        withdrawals.setGateway(address(gateway));
        gateway.setWithdrawalsContract(address(withdrawals));
        usdc.grantRole(usdc.MINTER_ROLE(), address(gateway));
        gateway.addSupportedToken(address(usdc));
        gateway.setMinWithdrawAmount(1 * 10 ** 18); // lower min for testing

        // Deploy PayoutEscrow
        escrow = new PayoutEscrow(address(mobileNFT), address(gateway), EXPIRY);

        // Authorize PayoutEscrow on Gateway
        gateway.setAuthorizedContract(address(escrow), true);

        // Authorize business sender
        escrow.setAuthorizedSender(business, true);

        vm.stopPrank();

        // Register recipient NFTs
        vm.prank(recipient);
        mobileNFT.registerMobile(PHONE_BYTES, "GH");

        vm.prank(recipient2);
        mobileNFT.registerMobile(PHONE2_BYTES, "GH");

        phoneHash = keccak256(PHONE_BYTES);
        phone2Hash = keccak256(PHONE2_BYTES);

        // Business approves escrow to pull tokens
        vm.prank(business);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Helper
    // -------------------------------------------------------------------------

    function _payoutId(string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(label));
    }

    // -------------------------------------------------------------------------
    // createPayout
    // -------------------------------------------------------------------------

    function test_CreatePayout_Success() public {
        bytes32 pid = _payoutId("p1");

        vm.expectEmit(true, true, false, true);
        emit IPayoutEscrow.PayoutCreated(pid, business, address(usdc), AMOUNT, phoneHash);

        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        IPayoutEscrow.Payout memory p = escrow.getPayout(pid);
        assertEq(p.sender, business);
        assertEq(p.token, address(usdc));
        assertEq(p.amount, AMOUNT);
        assertEq(p.phoneHash, phoneHash);
        assertEq(uint8(p.status), uint8(IPayoutEscrow.PayoutStatus.Pending));
        assertGt(p.expiresAt, block.timestamp);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT);
    }

    function test_CreatePayout_RevertUnauthorizedSender() public {
        vm.prank(attacker);
        vm.expectRevert(PayoutEscrow.NotAuthorizedSender.selector);
        escrow.createPayout(_payoutId("p2"), address(usdc), AMOUNT, phoneHash, 0);
    }

    function test_CreatePayout_RevertDuplicateId() public {
        bytes32 pid = _payoutId("dup");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        vm.prank(business);
        vm.expectRevert(PayoutEscrow.PayoutAlreadyExists.selector);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);
    }

    function test_CreatePayout_RevertZeroAmount() public {
        vm.prank(business);
        vm.expectRevert(PayoutEscrow.ZeroAmount.selector);
        escrow.createPayout(_payoutId("p3"), address(usdc), 0, phoneHash, 0);
    }

    function test_CreatePayout_CustomExpiry() public {
        bytes32 pid = _payoutId("p4");
        uint256 customExpiry = block.timestamp + 7 days;
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, customExpiry);

        IPayoutEscrow.Payout memory p = escrow.getPayout(pid);
        assertEq(p.expiresAt, customExpiry);
    }

    // -------------------------------------------------------------------------
    // createBatchPayout
    // -------------------------------------------------------------------------

    function test_CreateBatchPayout_Success() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = _payoutId("b1");
        ids[1] = _payoutId("b2");

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50 * 10 ** 18;
        amounts[1] = 75 * 10 ** 18;

        bytes32[] memory phones = new bytes32[](2);
        phones[0] = phoneHash;
        phones[1] = phone2Hash;

        vm.prank(business);
        escrow.createBatchPayout(ids, address(usdc), amounts, phones, 0);

        assertEq(escrow.getPayout(ids[0]).amount, amounts[0]);
        assertEq(escrow.getPayout(ids[1]).amount, amounts[1]);
        assertEq(usdc.balanceOf(address(escrow)), amounts[0] + amounts[1]);
    }

    function test_CreateBatchPayout_RevertArrayMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        uint256[] memory amounts = new uint256[](1); // mismatch
        bytes32[] memory phones = new bytes32[](2);

        vm.prank(business);
        vm.expectRevert(PayoutEscrow.ArrayLengthMismatch.selector);
        escrow.createBatchPayout(ids, address(usdc), amounts, phones, 0);
    }

    // -------------------------------------------------------------------------
    // claim
    // -------------------------------------------------------------------------

    function test_Claim_Success() public {
        bytes32 pid = _payoutId("c1");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        uint256 balBefore = usdc.balanceOf(recipient);

        vm.expectEmit(true, true, false, true);
        emit IPayoutEscrow.PayoutClaimed(pid, recipient, AMOUNT);

        vm.prank(recipient);
        escrow.claim(pid);

        assertEq(usdc.balanceOf(recipient), balBefore + AMOUNT);
        assertEq(uint8(escrow.getPayout(pid).status), uint8(IPayoutEscrow.PayoutStatus.Claimed));
        assertEq(escrow.getPayout(pid).recipient, recipient);
        assertGt(escrow.getPayout(pid).claimedAt, 0);
    }

    function test_Claim_RevertPhoneHashMismatch() public {
        bytes32 pid = _payoutId("c2");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phone2Hash, 0); // belongs to recipient2

        vm.prank(recipient); // wrong person
        vm.expectRevert(PayoutEscrow.PhoneHashMismatch.selector);
        escrow.claim(pid);
    }

    function test_Claim_RevertNoMobileNFT() public {
        bytes32 pid = _payoutId("c3");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        vm.prank(attacker); // has no NFT
        vm.expectRevert(PayoutEscrow.NoMobileNFT.selector);
        escrow.claim(pid);
    }

    function test_Claim_RevertAlreadyClaimed() public {
        bytes32 pid = _payoutId("c4");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        vm.prank(recipient);
        escrow.claim(pid);

        vm.prank(recipient);
        vm.expectRevert(PayoutEscrow.NotPending.selector);
        escrow.claim(pid);
    }

    function test_Claim_RevertPayoutNotFound() public {
        vm.prank(recipient);
        vm.expectRevert(PayoutEscrow.PayoutNotFound.selector);
        escrow.claim(_payoutId("nonexistent"));
    }

    // -------------------------------------------------------------------------
    // claimToMoMo
    // -------------------------------------------------------------------------

    function test_ClaimToMoMo_Success() public {
        bytes32 pid = _payoutId("momo1");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        // After claimToMoMo the withdrawal should be created (funds leave escrow)
        vm.prank(recipient);
        escrow.claimToMoMo(pid, "0244000000");

        assertEq(uint8(escrow.getPayout(pid).status), uint8(IPayoutEscrow.PayoutStatus.Claimed));
        assertEq(escrow.getPayout(pid).recipient, recipient);
        // Tokens went to Withdrawals contract via offrampFor
        assertGt(usdc.balanceOf(address(withdrawals)), 0);
    }

    function test_ClaimToMoMo_RevertGatewayNotSet() public {
        // Deploy fresh escrow with no gateway
        vm.prank(owner);
        PayoutEscrow freshEscrow = new PayoutEscrow(address(mobileNFT), address(0), EXPIRY);
        vm.prank(owner);
        freshEscrow.setAuthorizedSender(business, true);

        vm.prank(business);
        usdc.approve(address(freshEscrow), type(uint256).max);

        bytes32 pid = _payoutId("momo2");
        vm.prank(business);
        freshEscrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        vm.prank(recipient);
        vm.expectRevert(PayoutEscrow.GatewayNotSet.selector);
        freshEscrow.claimToMoMo(pid, "0244000000");
    }

    // -------------------------------------------------------------------------
    // refund
    // -------------------------------------------------------------------------

    function test_Refund_Success_AfterExpiry() public {
        bytes32 pid = _payoutId("r1");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        uint256 bizBefore = usdc.balanceOf(business);

        // Warp past expiry
        vm.warp(block.timestamp + EXPIRY + 1);

        vm.expectEmit(true, true, false, true);
        emit IPayoutEscrow.PayoutRefunded(pid, business, AMOUNT);

        vm.prank(business);
        escrow.refund(pid);

        assertEq(usdc.balanceOf(business), bizBefore + AMOUNT);
        assertEq(uint8(escrow.getPayout(pid).status), uint8(IPayoutEscrow.PayoutStatus.Refunded));
    }

    function test_Refund_ByOwner() public {
        bytes32 pid = _payoutId("r2");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        vm.warp(block.timestamp + EXPIRY + 1);

        vm.prank(owner); // owner can also refund
        escrow.refund(pid);

        assertEq(uint8(escrow.getPayout(pid).status), uint8(IPayoutEscrow.PayoutStatus.Refunded));
    }

    function test_Refund_RevertNotExpiredYet() public {
        bytes32 pid = _payoutId("r3");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        vm.prank(business);
        vm.expectRevert(PayoutEscrow.NotExpiredYet.selector);
        escrow.refund(pid);
    }

    function test_Refund_RevertUnauthorized() public {
        bytes32 pid = _payoutId("r4");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        vm.warp(block.timestamp + EXPIRY + 1);

        vm.prank(attacker);
        vm.expectRevert(PayoutEscrow.NotRefundEligible.selector);
        escrow.refund(pid);
    }

    function test_Refund_RevertAlreadyClaimed() public {
        bytes32 pid = _payoutId("r5");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        vm.prank(recipient);
        escrow.claim(pid);

        vm.warp(block.timestamp + EXPIRY + 1);

        vm.prank(business);
        vm.expectRevert(PayoutEscrow.NotPending.selector);
        escrow.refund(pid);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    function test_GetPayoutsForPhone() public {
        bytes32 pid1 = _payoutId("v1");
        bytes32 pid2 = _payoutId("v2");
        vm.startPrank(business);
        escrow.createPayout(pid1, address(usdc), AMOUNT, phoneHash, 0);
        escrow.createPayout(pid2, address(usdc), AMOUNT, phoneHash, 0);
        vm.stopPrank();

        bytes32[] memory ids = escrow.getPayoutsForPhone(phoneHash);
        assertEq(ids.length, 2);
        assertEq(ids[0], pid1);
        assertEq(ids[1], pid2);
    }

    function test_GetPayoutsByStatus_Pending() public {
        bytes32 pid1 = _payoutId("s1");
        bytes32 pid2 = _payoutId("s2");
        vm.startPrank(business);
        escrow.createPayout(pid1, address(usdc), AMOUNT, phoneHash, 0);
        escrow.createPayout(pid2, address(usdc), AMOUNT, phoneHash, 0);
        vm.stopPrank();

        vm.prank(recipient);
        escrow.claim(pid1); // claim one

        bytes32[] memory pending = escrow.getPayoutsByStatus(phoneHash, IPayoutEscrow.PayoutStatus.Pending);
        assertEq(pending.length, 1);
        assertEq(pending[0], pid2);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function test_SetAuthorizedSender_OnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        escrow.setAuthorizedSender(attacker, true);
    }

    function test_SetGateway() public {
        vm.prank(owner);
        escrow.setGateway(address(gateway));
        assertEq(address(escrow.gateway()), address(gateway));
    }

    function test_SetDefaultExpiryDuration() public {
        vm.prank(owner);
        escrow.setDefaultExpiryDuration(7 days);
        assertEq(escrow.defaultExpiryDuration(), 7 days);
    }

    function test_Pause_BlocksClaim() public {
        bytes32 pid = _payoutId("pause1");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        vm.prank(owner);
        escrow.pause();

        vm.prank(recipient);
        vm.expectRevert();
        escrow.claim(pid);
    }

    function test_Pause_BlocksCreatePayout() public {
        vm.prank(owner);
        escrow.pause();

        vm.prank(business);
        vm.expectRevert();
        escrow.createPayout(_payoutId("pause2"), address(usdc), AMOUNT, phoneHash, 0);
    }

    function test_Unpause_RestoresClaim() public {
        bytes32 pid = _payoutId("pause3");
        vm.prank(business);
        escrow.createPayout(pid, address(usdc), AMOUNT, phoneHash, 0);

        vm.prank(owner);
        escrow.pause();
        vm.prank(owner);
        escrow.unpause();

        vm.prank(recipient);
        escrow.claim(pid); // should succeed now
        assertEq(uint8(escrow.getPayout(pid).status), uint8(IPayoutEscrow.PayoutStatus.Claimed));
    }
}
