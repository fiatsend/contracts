// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultController} from "../src/liquidity/VaultController.sol";
import {GHSFIAT} from "../src/tokens/GHSFIAT.sol";
import {IVault} from "../src/interfaces/IVault.sol";

contract VaultControllerTest is Test {
    VaultController public vault;
    GHSFIAT public token;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    address public user2 = makeAddr("user2");

    uint256 public constant ANNUAL_YIELD = 500; // 5% APY
    uint256 public constant MIN_DEPOSIT = 10 * 10 ** 18;
    uint256 public constant DEPOSIT_AMOUNT = 1000 * 10 ** 18;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.startPrank(owner);
        token = new GHSFIAT(owner);
        vault = new VaultController(address(token), ANNUAL_YIELD, MIN_DEPOSIT);

        token.grantRole(token.MINTER_ROLE(), owner);
        token.mint(user, 100_000 * 10 ** 18);
        token.mint(user2, 100_000 * 10 ** 18);
        // Mint some to the vault itself to cover yield payouts
        token.mint(address(vault), 100_000 * 10 ** 18);

        vm.stopPrank();

        vm.prank(user);
        token.approve(address(vault), type(uint256).max);

        vm.prank(user2);
        token.approve(address(vault), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Deployment
    // -------------------------------------------------------------------------

    function test_Deployment() public view {
        assertEq(address(vault.supportedToken()), address(token));
        assertEq(vault.annualYieldRate(), ANNUAL_YIELD);
        assertEq(vault.minDeposit(), MIN_DEPOSIT);
        assertEq(vault.totalDeposited(), 0);
        assertEq(vault.owner(), owner);
    }

    // -------------------------------------------------------------------------
    // Deposit
    // -------------------------------------------------------------------------

    function test_Deposit_Success() public {
        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);

        IVault.VaultInfo memory info = vault.getVault(user);
        assertEq(info.balance, DEPOSIT_AMOUNT);
        assertEq(vault.totalDeposited(), DEPOSIT_AMOUNT);
        assertGt(info.depositedAt, 0);
    }

    function test_Deposit_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IVault.VaultDeposited(user, DEPOSIT_AMOUNT);

        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);
    }

    function test_Deposit_RevertBelowMin() public {
        vm.prank(user);
        vm.expectRevert(VaultController.BelowMinDeposit.selector);
        vault.deposit(1 * 10 ** 18);
    }

    function test_Deposit_RevertZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(VaultController.ZeroAmount.selector);
        vault.deposit(0);
    }

    // -------------------------------------------------------------------------
    // Withdraw
    // -------------------------------------------------------------------------

    function test_Withdraw_Success() public {
        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);

        uint256 balBefore = token.balanceOf(user);
        vm.prank(user);
        vault.withdraw(DEPOSIT_AMOUNT);

        assertEq(vault.getVault(user).balance, 0);
        // User gets back deposit (+ any yield auto-claimed)
        assertGe(token.balanceOf(user), balBefore + DEPOSIT_AMOUNT);
    }

    function test_Withdraw_EmitsEvent() public {
        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit IVault.VaultWithdrawn(user, DEPOSIT_AMOUNT);

        vm.prank(user);
        vault.withdraw(DEPOSIT_AMOUNT);
    }

    function test_Withdraw_RevertInsufficientBalance() public {
        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(VaultController.InsufficientBalance.selector);
        vault.withdraw(DEPOSIT_AMOUNT + 1);
    }

    // -------------------------------------------------------------------------
    // Yield
    // -------------------------------------------------------------------------

    function test_CalculateYield_AfterOneYear() public {
        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);

        vm.warp(block.timestamp + 365 days);

        uint256 expectedYield = (DEPOSIT_AMOUNT * ANNUAL_YIELD * 365 days) / (365 days * 10_000);
        uint256 actualYield = vault.calculateYield(user);

        assertEq(actualYield, expectedYield);
    }

    function test_ClaimYield_Success() public {
        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);

        vm.warp(block.timestamp + 365 days);

        uint256 expectedYield = vault.calculateYield(user);
        uint256 balBefore = token.balanceOf(user);

        vm.prank(user);
        vault.claimYield();

        assertGe(token.balanceOf(user), balBefore + expectedYield);
        assertEq(vault.calculateYield(user), 0);
    }

    function test_ClaimYield_RevertNoYield() public {
        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);

        // No time has passed
        vm.prank(user);
        vm.expectRevert(VaultController.NoYieldAvailable.selector);
        vault.claimYield();
    }

    function test_YieldAutoClaimedOnDeposit() public {
        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);

        vm.warp(block.timestamp + 180 days);

        uint256 yieldBefore = vault.calculateYield(user);
        assertGt(yieldBefore, 0);

        uint256 balBefore = token.balanceOf(user);
        vm.prank(user);
        vault.deposit(MIN_DEPOSIT);

        // Yield should have been auto-claimed
        assertGt(token.balanceOf(user), balBefore - MIN_DEPOSIT);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function test_SetAnnualYieldRate() public {
        vm.prank(owner);
        vault.setAnnualYieldRate(1000); // 10%

        assertEq(vault.annualYieldRate(), 1000);
    }

    function test_SetAnnualYieldRate_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IVault.YieldRateUpdated(1000);

        vm.prank(owner);
        vault.setAnnualYieldRate(1000);
    }

    function test_SetAnnualYieldRate_RevertTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(VaultController.InvalidYieldRate.selector);
        vault.setAnnualYieldRate(5001); // > 50%
    }

    function test_SetAnnualYieldRate_RevertNonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        vault.setAnnualYieldRate(1000);
    }
}
