// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Withdrawals
/// @notice Manages withdrawal lifecycle: pending → processing → completed/failed.
///         Only the gateway can create withdrawals. Owner manages status transitions.
contract Withdrawals is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error OnlyGateway();
    error WithdrawalNotFound();
    error InvalidStatus();
    error ZeroAddress();
    error ZeroAmount();

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    uint8 public constant STATUS_PENDING = 1;
    uint8 public constant STATUS_PROCESSING = 2;
    uint8 public constant STATUS_COMPLETED = 3;
    uint8 public constant STATUS_FAILED = 4;

    struct Withdrawal {
        uint256 id;
        address user;
        address token;
        uint256 amount;
        uint256 fee;
        uint8 status;
        uint8 paymentMethod;
        string phoneNumber;
        uint256 createdAt;
        uint256 completedAt;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event WithdrawalCreated(
        uint256 indexed id, address indexed user, address token, uint256 amount, uint256 fee, string phoneNumber
    );
    event WithdrawalProcessing(uint256 indexed id);
    event WithdrawalCompleted(uint256 indexed id, uint256 completedAt);
    event WithdrawalFailed(uint256 indexed id, address indexed user, uint256 refundAmount);
    event GatewayUpdated(address indexed gateway);

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    address public gateway;
    uint256 public withdrawalCounter;

    mapping(uint256 => Withdrawal) private _withdrawals;
    mapping(address => uint256[]) private _userWithdrawals;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor() Ownable(msg.sender) {}

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyGateway() {
        if (msg.sender != gateway) revert OnlyGateway();
        _;
    }

    // -------------------------------------------------------------------------
    // External: Admin
    // -------------------------------------------------------------------------

    /// @notice Sets the authorized gateway address (owner only).
    /// @param _gateway The gateway contract address.
    function setGateway(address _gateway) external onlyOwner {
        if (_gateway == address(0)) revert ZeroAddress();
        gateway = _gateway;
        emit GatewayUpdated(_gateway);
    }

    // -------------------------------------------------------------------------
    // External: Gateway-only
    // -------------------------------------------------------------------------

    /// @notice Creates a new withdrawal record. Only callable by the gateway.
    /// @param user The user initiating the withdrawal.
    /// @param token The token being withdrawn.
    /// @param amount The net amount (after fee) to be sent.
    /// @param fee The fee amount deducted.
    /// @param paymentMethod Encoded payment method (e.g., 1=MTN, 2=Telecel).
    /// @param phoneNumber The destination phone number for mobile money.
    function createWithdrawal(
        address user,
        address token,
        uint256 amount,
        uint256 fee,
        uint8 paymentMethod,
        string calldata phoneNumber
    ) external onlyGateway returns (uint256 id) {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        id = ++withdrawalCounter;
        _withdrawals[id] = Withdrawal({
            id: id,
            user: user,
            token: token,
            amount: amount,
            fee: fee,
            status: STATUS_PENDING,
            paymentMethod: paymentMethod,
            phoneNumber: phoneNumber,
            createdAt: block.timestamp,
            completedAt: 0
        });
        _userWithdrawals[user].push(id);

        emit WithdrawalCreated(id, user, token, amount, fee, phoneNumber);
    }

    // -------------------------------------------------------------------------
    // External: Owner — Status management
    // -------------------------------------------------------------------------

    /// @notice Marks a withdrawal as processing (owner only).
    /// @param id The withdrawal ID.
    function processWithdrawal(uint256 id) external onlyOwner {
        Withdrawal storage w = _getWithdrawal(id);
        if (w.status != STATUS_PENDING) revert InvalidStatus();
        w.status = STATUS_PROCESSING;
        emit WithdrawalProcessing(id);
    }

    /// @notice Marks a withdrawal as completed (owner only).
    /// @param id The withdrawal ID.
    function completeWithdrawal(uint256 id) external onlyOwner {
        Withdrawal storage w = _getWithdrawal(id);
        if (w.status != STATUS_PROCESSING) revert InvalidStatus();
        w.status = STATUS_COMPLETED;
        w.completedAt = block.timestamp;
        emit WithdrawalCompleted(id, block.timestamp);
    }

    /// @notice Marks a withdrawal as failed and refunds tokens to the user (owner only).
    /// @param id The withdrawal ID.
    function failWithdrawal(uint256 id) external onlyOwner nonReentrant {
        Withdrawal storage w = _getWithdrawal(id);
        if (w.status != STATUS_PROCESSING && w.status != STATUS_PENDING) revert InvalidStatus();

        // Refund only the net amount — the fee was already sent to treasury and is non-refundable.
        uint256 refund = w.amount;
        w.status = STATUS_FAILED;
        w.completedAt = block.timestamp;

        IERC20(w.token).safeTransfer(w.user, refund);
        emit WithdrawalFailed(id, w.user, refund);
    }

    // -------------------------------------------------------------------------
    // External: View
    // -------------------------------------------------------------------------

    /// @notice Returns a withdrawal record by ID.
    /// @param id The withdrawal ID.
    function getWithdrawal(uint256 id) external view returns (Withdrawal memory) {
        return _getWithdrawal(id);
    }

    /// @notice Returns all withdrawal IDs for a user.
    /// @param user The user address.
    function getUserWithdrawals(address user) external view returns (uint256[] memory) {
        return _userWithdrawals[user];
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _getWithdrawal(uint256 id) internal view returns (Withdrawal storage) {
        if (_withdrawals[id].id == 0) revert WithdrawalNotFound();
        return _withdrawals[id];
    }
}
