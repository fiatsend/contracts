// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IP2PExchange
/// @notice Interface for peer-to-peer token exchange with exact payment references.
///         Supports exchange-platform auto-completion flows (Binance P2P, Paxful, etc.).
interface IP2PExchange {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum OrderStatus {
        Open, //      0 — waiting for a taker
        Locked, //    1 — taker committed, awaiting payment confirmation
        Completed, // 2 — maker confirmed payment received; tokens released to taker
        Cancelled, // 3 — cancelled by maker before being taken
        Disputed //   4 — dispute raised; pending resolver decision
    }

    struct P2POrder {
        bytes32 id;
        address maker;
        address taker; // address(0) until taken
        address token;
        uint256 amount;
        string paymentReference; // exact reference for the exchange platform
        string exchangePlatform; // e.g., "binance", "paxful", "noones"
        OrderStatus status;
        uint256 createdAt;
        uint256 lockedAt;
        uint256 completedAt;
        uint256 expiryDuration; // seconds after creation before auto-cancellable
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event OrderCreated(
        bytes32 indexed orderId,
        address indexed maker,
        address token,
        uint256 amount,
        string paymentReference,
        string exchangePlatform
    );
    event OrderTaken(bytes32 indexed orderId, address indexed taker);
    event OrderCompleted(bytes32 indexed orderId, address indexed taker, uint256 amount);
    event OrderCancelled(bytes32 indexed orderId);
    event OrderDisputed(bytes32 indexed orderId, address indexed disputedBy);
    event DisputeResolved(bytes32 indexed orderId, address indexed winner, uint256 amount);
    event DisputeResolverSet(address indexed resolver);

    // -------------------------------------------------------------------------
    // State-changing functions
    // -------------------------------------------------------------------------

    /// @notice Creates a new P2P order and escrows tokens from maker.
    /// @param orderId          Unique order ID (off-chain generated or on-chain hash).
    /// @param token            Token to sell.
    /// @param amount           Token amount to escrow.
    /// @param paymentReference Exact reference string the taker must use on the exchange.
    /// @param exchangePlatform Exchange platform identifier.
    /// @param expiryDuration   Seconds until the order can be auto-cancelled if not taken.
    function createOrder(
        bytes32 orderId,
        address token,
        uint256 amount,
        string calldata paymentReference,
        string calldata exchangePlatform,
        uint256 expiryDuration
    ) external;

    /// @notice Locks an open order. Taker commits to pay via the exchange reference.
    function takeOrder(bytes32 orderId) external;

    /// @notice Maker confirms payment received on exchange. Releases tokens to taker.
    function confirmPayment(bytes32 orderId) external;

    /// @notice Maker cancels an open (not yet taken) order. Returns tokens.
    function cancelOrder(bytes32 orderId) external;

    /// @notice Either party raises a dispute on a locked order.
    function disputeOrder(bytes32 orderId) external;

    /// @notice Dispute resolver decides the winner and releases escrowed tokens.
    function resolveDispute(bytes32 orderId, address winner) external;

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the full order struct.
    function getOrder(bytes32 orderId) external view returns (P2POrder memory);

    /// @notice Returns all order IDs created by a user.
    function getUserOrders(address user) external view returns (bytes32[] memory);

    /// @notice Returns the first `limit` open order IDs (for discovery).
    function getOpenOrders(uint256 limit) external view returns (bytes32[] memory);

    // -------------------------------------------------------------------------
    // Admin functions
    // -------------------------------------------------------------------------

    /// @notice Sets the dispute resolver address.
    function setDisputeResolver(address resolver) external;

    /// @notice Pauses order creation.
    function pause() external;

    /// @notice Unpauses operations.
    function unpause() external;
}
