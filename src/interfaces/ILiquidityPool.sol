// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILiquidityPool
/// @notice Interface for the liquidity pool that earns conversion fees
interface ILiquidityPool {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    struct PoolInfo {
        uint256 totalDeposits;
        uint256 rewardPerToken;
        address supportedToken;
        uint256 minDeposit;
        uint256 lockPeriod;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a user deposits into the pool
    event Deposited(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws from the pool
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when a user claims fee rewards
    event RewardsClaimed(address indexed user, uint256 amount);

    /// @notice Emitted when rewards are distributed by the gateway
    event RewardsDistributed(uint256 amount);

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the pending rewards for a user
    function getRewards(address user) external view returns (uint256);

    /// @notice Returns pool statistics
    function getPoolInfo() external view returns (PoolInfo memory);

    /// @notice Returns the deposit balance for a user
    function getDeposit(address user) external view returns (uint256);

    // -------------------------------------------------------------------------
    // State-changing functions
    // -------------------------------------------------------------------------

    /// @notice Deposits stablecoins into the pool
    function deposit(uint256 amount) external;

    /// @notice Withdraws stablecoins after lock period
    function withdraw(uint256 amount) external;

    /// @notice Claims accumulated fee rewards
    function claimRewards() external;

    /// @notice Distributes fee rewards to LPs (called by gateway)
    function distributeRewards(uint256 amount) external;
}
