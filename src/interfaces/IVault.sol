// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVault
/// @notice Interface for the yield vault (passive stablecoin deposits)
interface IVault {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    struct VaultInfo {
        uint256 balance;
        uint256 depositedAt;
        uint256 lastYieldClaim;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a user deposits into their vault
    event VaultDeposited(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws from their vault
    event VaultWithdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when a user claims accrued yield
    event YieldClaimed(address indexed user, uint256 yieldAmount);

    /// @notice Emitted when the annual yield rate is updated
    event YieldRateUpdated(uint256 newRate);

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the vault state for a user
    function getVault(address user) external view returns (VaultInfo memory);

    /// @notice Returns the pending yield for a user
    function calculateYield(address user) external view returns (uint256);

    /// @notice Returns the annual yield rate in basis points
    function annualYieldRate() external view returns (uint256);

    // -------------------------------------------------------------------------
    // State-changing functions
    // -------------------------------------------------------------------------

    /// @notice Deposits stablecoins into the vault
    function deposit(uint256 amount) external;

    /// @notice Withdraws stablecoins from the vault
    function withdraw(uint256 amount) external;

    /// @notice Claims accrued yield
    function claimYield() external;

    /// @notice Sets the annual yield rate in basis points (owner only)
    function setAnnualYieldRate(uint256 rate) external;
}
