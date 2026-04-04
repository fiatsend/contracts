// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPaymentRouter
/// @notice Interface for P2P payments and payment request routing
interface IPaymentRouter {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    enum RequestStatus {
        Pending,
        Paid,
        Cancelled
    }

    struct PaymentRequest {
        uint256 id;
        address from; // address requesting payment
        address to; // address that should pay
        address token;
        uint256 amount;
        string memo;
        RequestStatus status;
        uint256 createdAt;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a direct P2P payment is sent
    event PaymentSent(address indexed from, address indexed to, address token, uint256 amount, string memo);

    /// @notice Emitted when a payment request is created
    event PaymentRequestCreated(
        uint256 indexed requestId, address indexed from, address indexed to, address token, uint256 amount
    );

    /// @notice Emitted when a payment request is fulfilled
    event PaymentRequestPaid(uint256 indexed requestId, address indexed paidBy);

    /// @notice Emitted when a payment request is cancelled
    event PaymentRequestCancelled(uint256 indexed requestId);

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns a payment request by ID
    function getPaymentRequest(uint256 requestId) external view returns (PaymentRequest memory);

    // -------------------------------------------------------------------------
    // State-changing functions
    // -------------------------------------------------------------------------

    /// @notice Sends tokens directly to an address
    function send(address token, address to, uint256 amount, string calldata memo) external;

    /// @notice Resolves a phone number via NFT and sends tokens
    function sendToPhone(address token, bytes calldata encryptedPhone, uint256 amount, string calldata memo)
        external;

    /// @notice Creates a payment request from another address
    function createPaymentRequest(address token, address from, uint256 amount, string calldata memo)
        external
        returns (uint256 requestId);

    /// @notice Pays a pending payment request
    function payRequest(uint256 requestId) external;

    /// @notice Cancels a pending payment request (request creator only)
    function cancelRequest(uint256 requestId) external;
}
