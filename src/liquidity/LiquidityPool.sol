// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidityPool} from "../interfaces/ILiquidityPool.sol";

/// @title LiquidityPool
/// @notice Liquidity providers deposit a supported stablecoin and earn
///         a proportional share of conversion fees distributed by the gateway.
///         Uses a per-share reward accumulator pattern for gas-efficient distribution.
contract LiquidityPool is Ownable, ReentrancyGuard, ILiquidityPool {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error BelowMinDeposit();
    error ZeroAmount();
    error LockPeriodActive();
    error InsufficientBalance();
    error OnlyGateway();
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 private constant PRECISION = 1e18;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IERC20 public immutable supportedToken;
    address public gateway;

    uint256 public minDeposit;
    uint256 public lockPeriod;
    uint256 public totalDeposits;
    uint256 public accRewardPerShare; // accumulated reward per share (scaled by PRECISION)

    mapping(address => uint256) private _deposits;
    mapping(address => uint256) private _rewardDebt;
    mapping(address => uint256) private _depositTimestamp;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _supportedToken, address _gateway, uint256 _minDeposit, uint256 _lockPeriod)
        Ownable(msg.sender)
    {
        if (_supportedToken == address(0)) revert ZeroAddress();
        supportedToken = IERC20(_supportedToken);
        gateway = _gateway;
        minDeposit = _minDeposit;
        lockPeriod = _lockPeriod;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyGateway() {
        if (msg.sender != gateway && msg.sender != owner()) revert OnlyGateway();
        _;
    }

    // -------------------------------------------------------------------------
    // External: LP actions
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityPool
    function deposit(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount < minDeposit) revert BelowMinDeposit();

        _settleRewards(msg.sender);

        supportedToken.safeTransferFrom(msg.sender, address(this), amount);
        _deposits[msg.sender] += amount;
        totalDeposits += amount;
        _depositTimestamp[msg.sender] = block.timestamp;
        _rewardDebt[msg.sender] = (_deposits[msg.sender] * accRewardPerShare) / PRECISION;

        emit Deposited(msg.sender, amount);
    }

    /// @inheritdoc ILiquidityPool
    function withdraw(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (_deposits[msg.sender] < amount) revert InsufficientBalance();
        if (block.timestamp < _depositTimestamp[msg.sender] + lockPeriod) revert LockPeriodActive();

        _settleRewards(msg.sender);

        _deposits[msg.sender] -= amount;
        totalDeposits -= amount;
        _rewardDebt[msg.sender] = (_deposits[msg.sender] * accRewardPerShare) / PRECISION;

        supportedToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @inheritdoc ILiquidityPool
    function claimRewards() external override nonReentrant {
        uint256 pending = _pendingRewards(msg.sender);
        if (pending == 0) revert ZeroAmount();

        _rewardDebt[msg.sender] = (_deposits[msg.sender] * accRewardPerShare) / PRECISION;
        supportedToken.safeTransfer(msg.sender, pending);

        emit RewardsClaimed(msg.sender, pending);
    }

    // -------------------------------------------------------------------------
    // External: Gateway — Reward distribution
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityPool
    function distributeRewards(uint256 amount) external override nonReentrant onlyGateway {
        if (amount == 0) revert ZeroAmount();
        if (totalDeposits == 0) {
            // No LPs — send rewards to owner
            supportedToken.safeTransferFrom(msg.sender, owner(), amount);
            return;
        }

        supportedToken.safeTransferFrom(msg.sender, address(this), amount);
        accRewardPerShare += (amount * PRECISION) / totalDeposits;

        emit RewardsDistributed(amount);
    }

    // -------------------------------------------------------------------------
    // External: Admin
    // -------------------------------------------------------------------------

    /// @notice Updates the gateway address (owner only).
    function setGateway(address _gateway) external onlyOwner {
        if (_gateway == address(0)) revert ZeroAddress();
        gateway = _gateway;
    }

    /// @notice Updates the minimum deposit amount (owner only).
    function setMinDeposit(uint256 _minDeposit) external onlyOwner {
        minDeposit = _minDeposit;
    }

    /// @notice Updates the lock period (owner only).
    function setLockPeriod(uint256 _lockPeriod) external onlyOwner {
        lockPeriod = _lockPeriod;
    }

    // -------------------------------------------------------------------------
    // External: View
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityPool
    function getRewards(address user) external view override returns (uint256) {
        return _pendingRewards(user);
    }

    /// @inheritdoc ILiquidityPool
    function getDeposit(address user) external view override returns (uint256) {
        return _deposits[user];
    }

    /// @inheritdoc ILiquidityPool
    function getPoolInfo() external view override returns (PoolInfo memory) {
        return PoolInfo({
            totalDeposits: totalDeposits,
            rewardPerToken: accRewardPerShare,
            supportedToken: address(supportedToken),
            minDeposit: minDeposit,
            lockPeriod: lockPeriod
        });
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _pendingRewards(address user) internal view returns (uint256) {
        if (_deposits[user] == 0) return 0;
        return (_deposits[user] * accRewardPerShare) / PRECISION - _rewardDebt[user];
    }

    function _settleRewards(address user) internal {
        uint256 pending = _pendingRewards(user);
        if (pending > 0) {
            _rewardDebt[user] += pending;
            supportedToken.safeTransfer(user, pending);
            emit RewardsClaimed(user, pending);
        }
    }
}
