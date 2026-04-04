// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IP2PExchange} from "../interfaces/IP2PExchange.sol";

/// @title P2PExchange
/// @notice Peer-to-peer token exchange with exact payment references for crypto-exchange auto-completion.
///         A maker escrows tokens on-chain; a taker pays off-chain using the exact reference; the maker
///         confirms receipt and tokens are released — or a dispute resolver adjudicates disagreements.
contract P2PExchange is Ownable, Pausable, ReentrancyGuard, IP2PExchange {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error OrderAlreadyExists();
    error OrderNotFound();
    error NotMaker();
    error NotParty();
    error NotDisputeResolver();
    error OrderNotOpen();
    error OrderNotLocked();
    error OrderNotDisputed();
    error AlreadyTaken();
    error SelfTake();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroExpiryDuration();
    error InvalidWinner();

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    address public disputeResolver;

    mapping(bytes32 => P2POrder) private _orders;
    mapping(address => bytes32[]) private _userOrders;

    // Open order index for discovery
    bytes32[] private _openOrderIds;
    mapping(bytes32 => uint256) private _openOrderIndex; // orderId → index+1 (0 = not in list)

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys P2PExchange.
    /// @param _disputeResolver Address authorized to resolve disputes.
    constructor(address _disputeResolver) Ownable(msg.sender) {
        if (_disputeResolver == address(0)) revert ZeroAddress();
        disputeResolver = _disputeResolver;
        emit DisputeResolverSet(_disputeResolver);
    }

    // -------------------------------------------------------------------------
    // External: Order lifecycle
    // -------------------------------------------------------------------------

    /// @inheritdoc IP2PExchange
    /// @dev Transfers `amount` tokens from maker to this contract as escrow.
    function createOrder(
        bytes32 orderId,
        address token,
        uint256 amount,
        string calldata paymentReference,
        string calldata exchangePlatform,
        uint256 expiryDuration
    ) external override nonReentrant whenNotPaused {
        if (_orders[orderId].createdAt != 0) revert OrderAlreadyExists();
        if (amount == 0) revert ZeroAmount();
        if (expiryDuration == 0) revert ZeroExpiryDuration();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        _orders[orderId] = P2POrder({
            id: orderId,
            maker: msg.sender,
            taker: address(0),
            token: token,
            amount: amount,
            paymentReference: paymentReference,
            exchangePlatform: exchangePlatform,
            status: OrderStatus.Open,
            createdAt: block.timestamp,
            lockedAt: 0,
            completedAt: 0,
            expiryDuration: expiryDuration
        });
        _userOrders[msg.sender].push(orderId);
        _addToOpenOrders(orderId);

        emit OrderCreated(orderId, msg.sender, token, amount, paymentReference, exchangePlatform);
    }

    /// @inheritdoc IP2PExchange
    /// @dev Taker commits to pay via the exchange using the paymentReference.
    function takeOrder(bytes32 orderId) external override nonReentrant whenNotPaused {
        P2POrder storage o = _requireStatus(orderId, OrderStatus.Open);
        if (msg.sender == o.maker) revert SelfTake();

        o.taker = msg.sender;
        o.status = OrderStatus.Locked;
        o.lockedAt = block.timestamp;
        _userOrders[msg.sender].push(orderId);
        _removeFromOpenOrders(orderId);

        emit OrderTaken(orderId, msg.sender);
    }

    /// @inheritdoc IP2PExchange
    /// @dev Only maker can confirm. Releases escrowed tokens to taker.
    function confirmPayment(bytes32 orderId) external override nonReentrant {
        P2POrder storage o = _requireStatus(orderId, OrderStatus.Locked);
        if (msg.sender != o.maker) revert NotMaker();

        address taker = o.taker;
        uint256 amount = o.amount;
        address token = o.token;

        o.status = OrderStatus.Completed;
        o.completedAt = block.timestamp;

        IERC20(token).safeTransfer(taker, amount);
        emit OrderCompleted(orderId, taker, amount);
    }

    /// @inheritdoc IP2PExchange
    /// @dev Only maker, only if open (not yet taken). Returns tokens.
    function cancelOrder(bytes32 orderId) external override nonReentrant {
        P2POrder storage o = _requireStatus(orderId, OrderStatus.Open);
        if (msg.sender != o.maker) revert NotMaker();

        address maker = o.maker;
        uint256 amount = o.amount;
        address token = o.token;

        o.status = OrderStatus.Cancelled;
        _removeFromOpenOrders(orderId);

        IERC20(token).safeTransfer(maker, amount);
        emit OrderCancelled(orderId);
    }

    /// @inheritdoc IP2PExchange
    /// @dev Either maker or taker can dispute a locked order.
    function disputeOrder(bytes32 orderId) external override {
        P2POrder storage o = _requireStatus(orderId, OrderStatus.Locked);
        if (msg.sender != o.maker && msg.sender != o.taker) revert NotParty();

        o.status = OrderStatus.Disputed;
        emit OrderDisputed(orderId, msg.sender);
    }

    /// @inheritdoc IP2PExchange
    /// @dev Only the disputeResolver. Winner receives escrowed tokens.
    function resolveDispute(bytes32 orderId, address winner) external override nonReentrant {
        if (msg.sender != disputeResolver) revert NotDisputeResolver();

        P2POrder storage o = _orders[orderId];
        if (o.createdAt == 0) revert OrderNotFound();
        if (o.status != OrderStatus.Disputed) revert OrderNotDisputed();
        if (winner != o.maker && winner != o.taker) revert InvalidWinner();

        uint256 amount = o.amount;
        address token = o.token;

        o.status = OrderStatus.Completed;
        o.completedAt = block.timestamp;

        IERC20(token).safeTransfer(winner, amount);
        emit DisputeResolved(orderId, winner, amount);
    }

    // -------------------------------------------------------------------------
    // External: View
    // -------------------------------------------------------------------------

    /// @inheritdoc IP2PExchange
    function getOrder(bytes32 orderId) external view override returns (P2POrder memory) {
        return _orders[orderId];
    }

    /// @inheritdoc IP2PExchange
    function getUserOrders(address user) external view override returns (bytes32[] memory) {
        return _userOrders[user];
    }

    /// @inheritdoc IP2PExchange
    /// @param limit Maximum number of open order IDs to return (0 = all).
    function getOpenOrders(uint256 limit) external view override returns (bytes32[] memory) {
        uint256 total = _openOrderIds.length;
        uint256 count = (limit == 0 || limit > total) ? total : limit;
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            result[i] = _openOrderIds[i];
        }
        return result;
    }

    // -------------------------------------------------------------------------
    // External: Admin
    // -------------------------------------------------------------------------

    /// @inheritdoc IP2PExchange
    function setDisputeResolver(address resolver) external override onlyOwner {
        if (resolver == address(0)) revert ZeroAddress();
        disputeResolver = resolver;
        emit DisputeResolverSet(resolver);
    }

    /// @inheritdoc IP2PExchange
    function pause() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc IP2PExchange
    function unpause() external override onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Fetches an order and asserts it has the expected status.
    function _requireStatus(bytes32 orderId, OrderStatus expected) internal view returns (P2POrder storage o) {
        o = _orders[orderId];
        if (o.createdAt == 0) revert OrderNotFound();
        if (expected == OrderStatus.Open && o.status != OrderStatus.Open) revert OrderNotOpen();
        if (expected == OrderStatus.Locked && o.status != OrderStatus.Locked) revert OrderNotLocked();
    }

    /// @dev Adds an order ID to the open-orders index.
    function _addToOpenOrders(bytes32 orderId) internal {
        _openOrderIds.push(orderId);
        _openOrderIndex[orderId] = _openOrderIds.length; // store index+1
    }

    /// @dev Removes an order ID from the open-orders index via swap-and-pop.
    function _removeFromOpenOrders(bytes32 orderId) internal {
        uint256 idxPlusOne = _openOrderIndex[orderId];
        if (idxPlusOne == 0) return;
        uint256 idx = idxPlusOne - 1;
        uint256 last = _openOrderIds.length - 1;
        if (idx != last) {
            bytes32 lastId = _openOrderIds[last];
            _openOrderIds[idx] = lastId;
            _openOrderIndex[lastId] = idxPlusOne;
        }
        _openOrderIds.pop();
        delete _openOrderIndex[orderId];
    }
}
