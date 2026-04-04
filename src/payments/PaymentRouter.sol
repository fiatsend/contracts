// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {IMobileNumberNFT} from "../interfaces/IMobileNumberNFT.sol";
import {IPayoutEscrow} from "../interfaces/IPayoutEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title PaymentRouter
/// @notice Routes P2P payments and payment requests between Fiatsend users.
///         Resolves recipients by phone number via MobileNumberNFT.
///         Integrates with PayoutEscrow for inbound B2B payout notifications.
contract PaymentRouter is Ownable, ReentrancyGuard, IPaymentRouter {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error PhoneNotRegistered();
    error RequestNotFound();
    error RequestNotPending();
    error NotRequestOwner();
    error NotRequestRecipient();
    error SelfPayment();

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IMobileNumberNFT public mobileNumberNFT;
    IPayoutEscrow public payoutEscrow;

    uint256 public p2pFeeRate; // basis points (0 = free P2P)
    address public feeTreasury;

    uint256 public paymentRequestCounter;
    mapping(uint256 => PaymentRequest) private _requests;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys the PaymentRouter.
    /// @param _mobileNumberNFT Address of the MobileNumberNFT contract.
    /// @param _feeTreasury     Address that receives P2P fees (may be address(0) for free P2P).
    constructor(address _mobileNumberNFT, address _feeTreasury) Ownable(msg.sender) {
        if (_mobileNumberNFT == address(0)) revert ZeroAddress();
        mobileNumberNFT = IMobileNumberNFT(_mobileNumberNFT);
        feeTreasury = _feeTreasury;
    }

    // -------------------------------------------------------------------------
    // External: Payments
    // -------------------------------------------------------------------------

    /// @inheritdoc IPaymentRouter
    function send(address token, address to, uint256 amount, string calldata memo) external override nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (to == msg.sender) revert SelfPayment();

        uint256 netAmount = _deductFeeAndTransferIn(token, amount);
        IERC20(token).safeTransfer(to, netAmount);

        emit PaymentSent(msg.sender, to, token, netAmount, memo);
    }

    /// @inheritdoc IPaymentRouter
    function sendToPhone(address token, bytes calldata encryptedPhone, uint256 amount, string calldata memo)
        external
        override
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();

        uint256 tokenId = mobileNumberNFT.getTokenIdByPhone(encryptedPhone);
        if (tokenId == 0) revert PhoneNotRegistered();

        address to = IERC721(address(mobileNumberNFT)).ownerOf(tokenId);
        if (to == msg.sender) revert SelfPayment();

        uint256 netAmount = _deductFeeAndTransferIn(token, amount);
        IERC20(token).safeTransfer(to, netAmount);

        emit PaymentSent(msg.sender, to, token, netAmount, memo);
    }

    // -------------------------------------------------------------------------
    // External: Payment requests
    // -------------------------------------------------------------------------

    /// @inheritdoc IPaymentRouter
    function createPaymentRequest(address token, address from, uint256 amount, string calldata memo)
        external
        override
        returns (uint256 requestId)
    {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (from == msg.sender) revert SelfPayment();

        requestId = ++paymentRequestCounter;
        _requests[requestId] = PaymentRequest({
            id: requestId,
            from: msg.sender, // requester
            to: from, // payer
            token: token,
            amount: amount,
            memo: memo,
            status: RequestStatus.Pending,
            createdAt: block.timestamp
        });

        emit PaymentRequestCreated(requestId, msg.sender, from, token, amount);
    }

    /// @inheritdoc IPaymentRouter
    function payRequest(uint256 requestId) external override nonReentrant {
        PaymentRequest storage req = _getRequest(requestId);
        if (req.status != RequestStatus.Pending) revert RequestNotPending();
        if (req.to != msg.sender) revert NotRequestRecipient();

        req.status = RequestStatus.Paid;

        uint256 netAmount = _deductFeeAndTransferIn(req.token, req.amount);
        IERC20(req.token).safeTransfer(req.from, netAmount);

        emit PaymentRequestPaid(requestId, msg.sender);
    }

    /// @inheritdoc IPaymentRouter
    function cancelRequest(uint256 requestId) external override {
        PaymentRequest storage req = _getRequest(requestId);
        if (req.status != RequestStatus.Pending) revert RequestNotPending();
        if (req.from != msg.sender) revert NotRequestOwner();

        req.status = RequestStatus.Cancelled;
        emit PaymentRequestCancelled(requestId);
    }

    // -------------------------------------------------------------------------
    // External: Admin
    // -------------------------------------------------------------------------

    /// @notice Sets the P2P fee rate in basis points (owner only).
    function setP2PFeeRate(uint256 rate) external onlyOwner {
        p2pFeeRate = rate;
    }

    /// @notice Sets the fee treasury address (owner only).
    function setFeeTreasury(address treasury) external onlyOwner {
        if (treasury == address(0)) revert ZeroAddress();
        feeTreasury = treasury;
    }

    /// @notice Sets the PayoutEscrow contract address (owner only).
    /// @dev Used for informational routing — callers can discover pending B2B payouts.
    function setPayoutEscrow(address _payoutEscrow) external onlyOwner {
        if (_payoutEscrow == address(0)) revert ZeroAddress();
        payoutEscrow = IPayoutEscrow(_payoutEscrow);
    }

    // -------------------------------------------------------------------------
    // External: View
    // -------------------------------------------------------------------------

    /// @inheritdoc IPaymentRouter
    function getPaymentRequest(uint256 requestId) external view override returns (PaymentRequest memory) {
        return _getRequest(requestId);
    }

    /// @notice Returns pending B2B payouts for a given phone hash (via PayoutEscrow).
    /// @dev Convenience view — the actual claim must be done directly on PayoutEscrow.
    function getPendingPayouts(bytes32 phoneHash) external view returns (bytes32[] memory) {
        if (address(payoutEscrow) == address(0)) return new bytes32[](0);
        return payoutEscrow.getPayoutsByStatus(phoneHash, IPayoutEscrow.PayoutStatus.Pending);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Pulls `amount` from sender, deducts fee, returns net amount.
    function _deductFeeAndTransferIn(address token, uint256 amount) internal returns (uint256 netAmount) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (p2pFeeRate > 0 && feeTreasury != address(0)) {
            uint256 fee = (amount * p2pFeeRate) / 10_000;
            if (fee > 0) {
                IERC20(token).safeTransfer(feeTreasury, fee);
            }
            netAmount = amount - fee;
        } else {
            netAmount = amount;
        }
    }

    function _getRequest(uint256 requestId) internal view returns (PaymentRequest storage) {
        if (_requests[requestId].id == 0) revert RequestNotFound();
        return _requests[requestId];
    }
}
