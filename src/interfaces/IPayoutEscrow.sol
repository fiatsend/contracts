// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPayoutEscrow
/// @notice Interface for the B2B payout escrow contract.
///         Businesses deposit stablecoins; recipients claim via their MobileNumberNFT identity.
interface IPayoutEscrow {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Lifecycle status of a payout
    enum PayoutStatus {
        Pending, // 0 — awaiting claim
        Claimed, // 1 — claimed by recipient
        Refunded, // 2 — refunded to sender
        Expired //  3 — marked expired (no funds remain)

    }

    struct Payout {
        bytes32 id;
        address sender; // business wallet that funded the payout
        address recipient; // resolved at claim time (address(0) until then)
        address token; // stablecoin address
        uint256 amount;
        bytes32 phoneHash; // keccak256 of recipient's encrypted phone bytes
        PayoutStatus status;
        uint256 expiresAt;
        uint256 createdAt;
        uint256 claimedAt;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PayoutCreated(
        bytes32 indexed payoutId, address indexed sender, address token, uint256 amount, bytes32 indexed phoneHash
    );
    event PayoutClaimed(bytes32 indexed payoutId, address indexed recipient, uint256 amount);
    event PayoutRefunded(bytes32 indexed payoutId, address indexed sender, uint256 amount);
    event PayoutExpired(bytes32 indexed payoutId);
    event AuthorizedSenderSet(address indexed sender, bool authorized);
    event GatewaySet(address indexed gateway);
    event DefaultExpiryDurationSet(uint256 duration);

    // -------------------------------------------------------------------------
    // State-changing functions
    // -------------------------------------------------------------------------

    /// @notice Creates a single payout. Transfers `amount` tokens from caller to escrow.
    /// @param payoutId      Unique ID generated off-chain by the API.
    /// @param token         Stablecoin address.
    /// @param amount        Token amount.
    /// @param phoneHash     keccak256 of the recipient's encrypted phone bytes.
    /// @param expiresAt     Expiry timestamp; pass 0 to use defaultExpiryDuration.
    function createPayout(bytes32 payoutId, address token, uint256 amount, bytes32 phoneHash, uint256 expiresAt)
        external;

    /// @notice Creates multiple payouts in one call (single token approval).
    function createBatchPayout(
        bytes32[] calldata payoutIds,
        address token,
        uint256[] calldata amounts,
        bytes32[] calldata phoneHashes,
        uint256 expiresAt
    ) external;

    /// @notice Caller claims a payout by proving their MobileNumberNFT phone hash matches.
    function claim(bytes32 payoutId) external;

    /// @notice Claims a payout and immediately routes funds through the gateway for MoMo offramp.
    function claimToMoMo(bytes32 payoutId, string calldata phoneNumber) external;

    /// @notice Refunds an expired pending payout back to the original sender.
    function refund(bytes32 payoutId) external;

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the full payout struct for a given ID.
    function getPayout(bytes32 payoutId) external view returns (Payout memory);

    /// @notice Returns all payout IDs associated with a phone hash.
    function getPayoutsForPhone(bytes32 phoneHash) external view returns (bytes32[] memory);

    /// @notice Returns payout IDs for a phone hash filtered by status.
    function getPayoutsByStatus(bytes32 phoneHash, PayoutStatus status) external view returns (bytes32[] memory);

    // -------------------------------------------------------------------------
    // Admin functions
    // -------------------------------------------------------------------------

    /// @notice Authorizes or deauthorizes a business sender address.
    function setAuthorizedSender(address sender, bool authorized) external;

    /// @notice Sets the default expiry duration for new payouts.
    function setDefaultExpiryDuration(uint256 duration) external;

    /// @notice Sets the gateway address for offramp routing.
    function setGateway(address gateway) external;

    /// @notice Pauses payout creation and claims.
    function pause() external;

    /// @notice Unpauses operations.
    function unpause() external;
}
