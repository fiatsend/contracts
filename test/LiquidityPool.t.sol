// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LiquidityPool} from "../src/liquidity/LiquidityPool.sol";
import {ILiquidityPool} from "../src/interfaces/ILiquidityPool.sol";
import {GHSFIAT} from "../src/tokens/GHSFIAT.sol";

contract LiquidityPoolTest is Test {
    LiquidityPool public pool;
    GHSFIAT public token;

    address public owner = makeAddr("owner");
    address public gateway = makeAddr("gateway");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");

    uint256 public constant MIN_DEPOSIT = 10 * 10 ** 18;
    uint256 public constant LOCK_PERIOD = 7 days;
    uint256 public constant DEPOSIT_AMOUNT = 100 * 10 ** 18;
    uint256 public constant REWARD_AMOUNT = 10 * 10 ** 18;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.startPrank(owner);

        token = new GHSFIAT(owner);
        pool = new LiquidityPool(address(token), gateway, MIN_DEPOSIT, LOCK_PERIOD);

        token.grantRole(token.MINTER_ROLE(), owner);
        token.mint(lp1, 1000 * 10 ** 18);
        token.mint(lp2, 1000 * 10 ** 18);
        token.mint(gateway, 1000 * 10 ** 18);

        vm.stopPrank();

        vm.prank(lp1);
        token.approve(address(pool), type(uint256).max);

        vm.prank(lp2);
        token.approve(address(pool), type(uint256).max);

        vm.prank(gateway);
        token.approve(address(pool), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Deployment
    // -------------------------------------------------------------------------

    function test_Deployment() public view {
        assertEq(address(pool.supportedToken()), address(token));
        assertEq(pool.gateway(), gateway);
        assertEq(pool.minDeposit(), MIN_DEPOSIT);
        assertEq(pool.lockPeriod(), LOCK_PERIOD);
        assertEq(pool.totalDeposits(), 0);
    }

    // -------------------------------------------------------------------------
    // Deposit
    // -------------------------------------------------------------------------

    function test_Deposit_Success() public {
        vm.prank(lp1);
        pool.deposit(DEPOSIT_AMOUNT);

        assertEq(pool.getDeposit(lp1), DEPOSIT_AMOUNT);
        assertEq(pool.totalDeposits(), DEPOSIT_AMOUNT);
    }

    function test_Deposit_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ILiquidityPool.Deposited(lp1, DEPOSIT_AMOUNT);

        vm.prank(lp1);
        pool.deposit(DEPOSIT_AMOUNT);
    }

    function test_Deposit_RevertBelowMin() public {
        vm.prank(lp1);
        vm.expectRevert(LiquidityPool.BelowMinDeposit.selector);
        pool.deposit(1 * 10 ** 18);
    }

    function test_Deposit_RevertZeroAmount() public {
        vm.prank(lp1);
        vm.expectRevert(LiquidityPool.ZeroAmount.selector);
        pool.deposit(0);
    }

    // -------------------------------------------------------------------------
    // Withdraw
    // -------------------------------------------------------------------------

    function test_Withdraw_AfterLockPeriod() public {
        vm.prank(lp1);
        pool.deposit(DEPOSIT_AMOUNT);

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        uint256 balBefore = token.balanceOf(lp1);
        vm.prank(lp1);
        pool.withdraw(DEPOSIT_AMOUNT);

        assertEq(pool.getDeposit(lp1), 0);
        assertEq(token.balanceOf(lp1), balBefore + DEPOSIT_AMOUNT);
    }

    function test_Withdraw_RevertDuringLock() public {
        vm.prank(lp1);
        pool.deposit(DEPOSIT_AMOUNT);

        vm.prank(lp1);
        vm.expectRevert(LiquidityPool.LockPeriodActive.selector);
        pool.withdraw(DEPOSIT_AMOUNT);
    }

    function test_Withdraw_RevertInsufficientBalance() public {
        vm.prank(lp1);
        pool.deposit(DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        vm.prank(lp1);
        vm.expectRevert(LiquidityPool.InsufficientBalance.selector);
        pool.withdraw(DEPOSIT_AMOUNT + 1);
    }

    // -------------------------------------------------------------------------
    // Rewards
    // -------------------------------------------------------------------------

    function test_DistributeAndClaimRewards() public {
        vm.prank(lp1);
        pool.deposit(DEPOSIT_AMOUNT);

        vm.prank(gateway);
        pool.distributeRewards(REWARD_AMOUNT);

        uint256 pendingRewards = pool.getRewards(lp1);
        assertEq(pendingRewards, REWARD_AMOUNT);

        uint256 balBefore = token.balanceOf(lp1);
        vm.prank(lp1);
        pool.claimRewards();

        assertEq(token.balanceOf(lp1), balBefore + REWARD_AMOUNT);
        assertEq(pool.getRewards(lp1), 0);
    }

    function test_RewardsProportionalToDeposit() public {
        vm.prank(lp1);
        pool.deposit(DEPOSIT_AMOUNT); // 50%

        vm.prank(lp2);
        pool.deposit(DEPOSIT_AMOUNT); // 50%

        vm.prank(gateway);
        pool.distributeRewards(REWARD_AMOUNT);

        // Each should get 50% of rewards
        assertEq(pool.getRewards(lp1), REWARD_AMOUNT / 2);
        assertEq(pool.getRewards(lp2), REWARD_AMOUNT / 2);
    }

    function test_DistributeRewards_RevertOnlyGateway() public {
        vm.prank(lp1);
        pool.deposit(DEPOSIT_AMOUNT);

        vm.prank(lp1);
        vm.expectRevert(LiquidityPool.OnlyGateway.selector);
        pool.distributeRewards(REWARD_AMOUNT);
    }

    function test_ClaimRewards_RevertZeroRewards() public {
        vm.prank(lp1);
        pool.deposit(DEPOSIT_AMOUNT);

        vm.prank(lp1);
        vm.expectRevert(LiquidityPool.ZeroAmount.selector);
        pool.claimRewards();
    }

    // -------------------------------------------------------------------------
    // Pool info
    // -------------------------------------------------------------------------

    function test_GetPoolInfo() public {
        vm.prank(lp1);
        pool.deposit(DEPOSIT_AMOUNT);

        LiquidityPool.PoolInfo memory info = pool.getPoolInfo();
        assertEq(info.totalDeposits, DEPOSIT_AMOUNT);
        assertEq(info.supportedToken, address(token));
        assertEq(info.minDeposit, MIN_DEPOSIT);
        assertEq(info.lockPeriod, LOCK_PERIOD);
    }
}
