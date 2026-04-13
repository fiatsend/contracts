// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FiatsendGateway} from "../src/payments/FiatsendGateway.sol";
import {IFiatsendGateway} from "../src/interfaces/IFiatsendGateway.sol";
import {GHSFIAT} from "../src/tokens/GHSFIAT.sol";
import {MobileNumberNFT} from "../src/identity/MobileNumberNFT.sol";
import {Withdrawals} from "../src/payments/Withdrawals.sol";

contract FiatsendGatewayTest is Test {
    FiatsendGateway public gateway;
    GHSFIAT public ghsFiat;
    MobileNumberNFT public mobileNFT;
    Withdrawals public withdrawals;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public user = makeAddr("user");
    address public user2 = makeAddr("user2");

    uint256 public constant FEE_RATE = 50; // 0.5%
    uint256 public constant AMOUNT = 100 * 10 ** 18;
    uint256 public constant LARGE_AMOUNT = 600 * 10 ** 18; // above KYC threshold

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.startPrank(owner);

        ghsFiat = new GHSFIAT(owner);
        mobileNFT = new MobileNumberNFT("https://api.fiatsend.com/identity/");
        withdrawals = new Withdrawals();

        FiatsendGateway impl = new FiatsendGateway();
        bytes memory initData = abi.encodeWithSelector(
            FiatsendGateway.initialize.selector, address(ghsFiat), address(mobileNFT), treasury, FEE_RATE
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        gateway = FiatsendGateway(address(proxy));

        // Wire up
        withdrawals.setGateway(address(gateway));
        gateway.setWithdrawalsContract(address(withdrawals));

        // Grant MINTER_ROLE to gateway
        ghsFiat.grantRole(ghsFiat.MINTER_ROLE(), address(gateway));

        // Add GHSFIAT as supported token
        gateway.addSupportedToken(address(ghsFiat));

        // Mint tokens to user for testing
        ghsFiat.grantRole(ghsFiat.MINTER_ROLE(), owner);
        ghsFiat.mint(user, 10_000 * 10 ** 18);
        ghsFiat.mint(user2, 10_000 * 10 ** 18);

        vm.stopPrank();

        // Register mobile NFT for user
        vm.prank(user);
        mobileNFT.registerMobile(bytes("phone1_encrypted"), "GH");

        vm.prank(user2);
        mobileNFT.registerMobile(bytes("phone2_encrypted"), "GH");

        // Approve gateway
        vm.prank(user);
        ghsFiat.approve(address(gateway), type(uint256).max);

        vm.prank(user2);
        ghsFiat.approve(address(gateway), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Deployment / initialization
    // -------------------------------------------------------------------------

    function test_Initialization() public view {
        assertEq(address(gateway.ghsFiatToken()), address(ghsFiat));
        assertEq(address(gateway.mobileNumberNFT()), address(mobileNFT));
        assertEq(gateway.protocolTreasury(), treasury);
        assertEq(gateway.protocolFeeRate(), FEE_RATE);
        assertEq(gateway.minWithdrawAmount(), 20 * 10 ** 18);
        assertEq(gateway.dailyLimit(), 10_000 * 10 ** 18);
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        gateway.initialize(address(ghsFiat), address(mobileNFT), treasury, FEE_RATE);
    }

    // -------------------------------------------------------------------------
    // Offramp
    // -------------------------------------------------------------------------

    function test_Offramp_Success() public {
        vm.prank(user);
        gateway.offramp(address(ghsFiat), AMOUNT, "0244000000");

        uint256 fee = (AMOUNT * FEE_RATE) / 10_000;
        uint256 netAmount = AMOUNT - fee;

        assertEq(ghsFiat.balanceOf(treasury), fee);
        assertEq(ghsFiat.balanceOf(address(withdrawals)), netAmount);
        assertEq(withdrawals.withdrawalCounter(), 1);
    }

    function test_Offramp_EmitsEvent() public {
        uint256 fee = (AMOUNT * FEE_RATE) / 10_000;

        vm.expectEmit(true, true, false, true);
        emit IFiatsendGateway.OfframpInitiated(user, address(ghsFiat), AMOUNT, fee, "0244000000");

        vm.prank(user);
        gateway.offramp(address(ghsFiat), AMOUNT, "0244000000");
    }

    function test_Offramp_RevertUnsupportedToken() public {
        address fakeToken = makeAddr("fakeToken");
        vm.prank(user);
        vm.expectRevert(FiatsendGateway.TokenNotSupported.selector);
        gateway.offramp(fakeToken, AMOUNT, "0244000000");
    }

    function test_Offramp_RevertNoMobileNFT() public {
        address noNFT = makeAddr("noNFT");
        vm.prank(owner);
        ghsFiat.mint(noNFT, AMOUNT * 10);
        vm.prank(noNFT);
        ghsFiat.approve(address(gateway), type(uint256).max);

        vm.prank(noNFT);
        vm.expectRevert(FiatsendGateway.NoMobileNFT.selector);
        gateway.offramp(address(ghsFiat), AMOUNT, "0244000000");
    }

    function test_Offramp_RevertBelowMinimum() public {
        vm.prank(user);
        vm.expectRevert(FiatsendGateway.BelowMinimum.selector);
        gateway.offramp(address(ghsFiat), 1 * 10 ** 18, "0244000000");
    }

    function test_Offramp_RevertKYCRequired() public {
        vm.prank(user);
        vm.expectRevert(FiatsendGateway.KYCRequired.selector);
        gateway.offramp(address(ghsFiat), LARGE_AMOUNT, "0244000000");
    }

    function test_Offramp_SuccessWithKYC() public {
        vm.prank(owner);
        gateway.setKYC(user, true);

        vm.prank(user);
        gateway.offramp(address(ghsFiat), LARGE_AMOUNT, "0244000000");

        assertEq(withdrawals.withdrawalCounter(), 1);
    }

    function test_Offramp_RevertDailyLimit() public {
        vm.prank(owner);
        gateway.setKYC(user, true);
        vm.prank(owner);
        gateway.setDailyLimit(50 * 10 ** 18); // set low limit

        vm.prank(user);
        vm.expectRevert(FiatsendGateway.DailyLimitExceeded.selector);
        gateway.offramp(address(ghsFiat), AMOUNT, "0244000000");
    }

    function test_Offramp_DailyLimitResetsNextDay() public {
        vm.prank(owner);
        gateway.setKYC(user, true);
        vm.prank(owner);
        gateway.setDailyLimit(AMOUNT);

        vm.prank(user);
        gateway.offramp(address(ghsFiat), AMOUNT, "0244000000");

        // Warp to next day
        vm.warp(block.timestamp + 1 days);

        vm.prank(user);
        gateway.offramp(address(ghsFiat), AMOUNT, "0244000000");
    }

    // -------------------------------------------------------------------------
    // Onramp
    // -------------------------------------------------------------------------

    function test_Onramp_ByOwner() public {
        uint256 mintAmount = 500 * 10 ** 18;
        vm.prank(owner);
        gateway.onramp(user2, mintAmount);

        assertEq(ghsFiat.balanceOf(user2), 10_000 * 10 ** 18 + mintAmount);
    }

    function test_Onramp_RevertUnauthorized() public {
        vm.prank(user);
        vm.expectRevert(FiatsendGateway.NotAuthorizedOnramp.selector);
        gateway.onramp(user2, 100 * 10 ** 18);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    function test_Pause_BlocksOfframp() public {
        vm.prank(owner);
        gateway.pause();

        vm.prank(user);
        vm.expectRevert();
        gateway.offramp(address(ghsFiat), AMOUNT, "0244000000");
    }

    function test_Unpause() public {
        vm.prank(owner);
        gateway.pause();

        vm.prank(owner);
        gateway.unpause();

        vm.prank(user);
        gateway.offramp(address(ghsFiat), AMOUNT, "0244000000");
    }

    // -------------------------------------------------------------------------
    // Access control
    // -------------------------------------------------------------------------

    function test_SetProtocolFee_RevertNonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        gateway.setProtocolFee(100);
    }

    function test_SetProtocolFee_RevertTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(FiatsendGateway.InvalidFeeRate.selector);
        gateway.setProtocolFee(1001); // > 10%
    }

    function test_EmergencyWithdraw() public {
        vm.prank(owner);
        ghsFiat.mint(address(gateway), 1000 * 10 ** 18);

        uint256 ownerBefore = ghsFiat.balanceOf(owner);
        vm.prank(owner);
        gateway.emergencyWithdraw(address(ghsFiat), 1000 * 10 ** 18);

        assertEq(ghsFiat.balanceOf(owner), ownerBefore + 1000 * 10 ** 18);
    }
}
