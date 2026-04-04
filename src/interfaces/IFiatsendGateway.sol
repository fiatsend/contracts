// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFiatsendGateway
/// @notice Interface for the core Fiatsend payment gateway (UUPS upgradeable)
interface IFiatsendGateway {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a user initiates an offramp (stablecoin → fiat)
    event OfframpInitiated(
        address indexed user, address indexed token, uint256 amount, uint256 fee, string phoneNumber
    );

    /// @notice Emitted when a user is onramped (fiat → GHSFIAT minted)
    event OnrampCompleted(address indexed user, uint256 amount);

    /// @notice Emitted when a conversion rate is updated
    event ConversionRateUpdated(address indexed token, uint256 rate);

    /// @notice Emitted when a token is added to supported list
    event TokenAdded(address indexed token);

    /// @notice Emitted when a token is removed from supported list
    event TokenRemoved(address indexed token);

    /// @notice Emitted when protocol fee is collected
    event FeeCollected(address indexed token, uint256 feeAmount, address treasury);

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns whether a token is supported by the gateway
    function isTokenSupported(address token) external view returns (bool);

    /// @notice Returns the conversion rate for a token (scaled)
    function getConversionRate(address token) external view returns (uint256);

    /// @notice Returns whether a user has passed KYC
    function isKYCPassed(address user) external view returns (bool);

    /// @notice Returns the current protocol fee rate in basis points
    function protocolFeeRate() external view returns (uint256);

    /// @notice Returns the protocol treasury address
    function protocolTreasury() external view returns (address);

    // -------------------------------------------------------------------------
    // State-changing functions
    // -------------------------------------------------------------------------

    /// @notice Converts stablecoin to a fiat withdrawal request
    function offramp(address token, uint256 amount, string calldata phoneNumber) external;

    /// @notice Triggers an offramp on behalf of a user (only authorized contracts).
    ///         Caller must have pre-approved the gateway to pull `amount` tokens.
    function offrampFor(address user, address token, uint256 amount, string calldata phoneNumber) external;

    /// @notice Mints GHSFIAT for a user (authorized callers only)
    function onramp(address user, uint256 amount) external;

    /// @notice Sets the conversion rate for a token (owner only)
    function setConversionRate(address token, uint256 rate) external;

    /// @notice Adds a token to the supported list (owner only)
    function addSupportedToken(address token) external;

    /// @notice Removes a token from the supported list (owner only)
    function removeSupportedToken(address token) external;

    /// @notice Sets KYC status for a user (owner only)
    function setKYC(address user, bool status) external;

    /// @notice Sets the protocol fee rate in basis points (owner only)
    function setProtocolFee(uint256 newFeeRate) external;

    /// @notice Sets the minimum withdrawal amount (owner only)
    function setMinWithdrawAmount(uint256 amount) external;

    /// @notice Sets the per-user daily limit (owner only)
    function setDailyLimit(uint256 limit) external;

    /// @notice Withdraws tokens in an emergency (owner only)
    function emergencyWithdraw(address token, uint256 amount) external;

    /// @notice Pauses all gateway operations (owner only)
    function pause() external;

    /// @notice Unpauses gateway operations (owner only)
    function unpause() external;
}
