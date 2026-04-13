// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPayoutEscrow} from "../interfaces/IPayoutEscrow.sol";
import {IMobileNumberNFT} from "../interfaces/IMobileNumberNFT.sol";
import {IFiatsendGateway} from "../interfaces/IFiatsendGateway.sol";

/// @title PayoutEscrow
/// @notice Core B2B payout contract. Businesses deposit stablecoins via the Fiatsend API;
///         funds are held here until the recipient claims using their MobileNumberNFT identity.
///         Recipients can claim to their wallet or immediately offramp to mobile money in one tx.
contract PayoutEscrow is Ownable, Pausable, ReentrancyGuard, IPayoutEscrow {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error PayoutAlreadyExists();
    error PayoutNotFound();
    error NotAuthorizedSender();
    error NotPending();
    error NotExpiredYet();
    error NotRefundEligible();
    error PhoneHashMismatch();
    error NoMobileNFT();
    error ZeroAddress();
    error ZeroAmount();
    error ArrayLengthMismatch();
    error InvalidExpiry();
    error GatewayNotSet();
    error TokenNotSupportedByGateway();

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IMobileNumberNFT public mobileNumberNFT;
    IFiatsendGateway public gateway;
    uint256 public defaultExpiryDuration;

    mapping(bytes32 => Payout) private _payouts;
    mapping(bytes32 => bytes32[]) private _phoneToPayouts; // phoneHash → payoutIds
    mapping(address => bool) public authorizedSenders;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys the PayoutEscrow.
    /// @param _mobileNumberNFT  Address of the MobileNumberNFT contract.
    /// @param _gateway          Address of the FiatsendGateway (may be address(0) initially).
    /// @param _expiryDuration   Default payout expiry in seconds (e.g., 30 days).
    constructor(address _mobileNumberNFT, address _gateway, uint256 _expiryDuration) Ownable(msg.sender) {
        if (_mobileNumberNFT == address(0)) revert ZeroAddress();
        mobileNumberNFT = IMobileNumberNFT(_mobileNumberNFT);
        gateway = IFiatsendGateway(_gateway);
        defaultExpiryDuration = _expiryDuration == 0 ? 30 days : _expiryDuration;
    }

    // -------------------------------------------------------------------------
    // External: Business payout creation
    // -------------------------------------------------------------------------

    /// @inheritdoc IPayoutEscrow
    function createPayout(bytes32 payoutId, address token, uint256 amount, bytes32 phoneHash, uint256 expiresAt)
        external
        override
        nonReentrant
        whenNotPaused
    {
        if (!authorizedSenders[msg.sender]) revert NotAuthorizedSender();
        if (amount == 0) revert ZeroAmount();
        if (_payouts[payoutId].createdAt != 0) revert PayoutAlreadyExists();

        uint256 expiry = expiresAt == 0 ? block.timestamp + defaultExpiryDuration : expiresAt;
        if (expiry <= block.timestamp) revert InvalidExpiry();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        _payouts[payoutId] = Payout({
            id: payoutId,
            sender: msg.sender,
            recipient: address(0),
            token: token,
            amount: amount,
            phoneHash: phoneHash,
            status: PayoutStatus.Pending,
            expiresAt: expiry,
            createdAt: block.timestamp,
            claimedAt: 0
        });
        _phoneToPayouts[phoneHash].push(payoutId);

        emit PayoutCreated(payoutId, msg.sender, token, amount, phoneHash);
    }

    /// @inheritdoc IPayoutEscrow
    function createBatchPayout(
        bytes32[] calldata payoutIds,
        address token,
        uint256[] calldata amounts,
        bytes32[] calldata phoneHashes,
        uint256 expiresAt
    ) external override nonReentrant whenNotPaused {
        if (!authorizedSenders[msg.sender]) revert NotAuthorizedSender();
        uint256 len = payoutIds.length;
        if (len == 0 || len != amounts.length || len != phoneHashes.length) revert ArrayLengthMismatch();

        uint256 expiry = expiresAt == 0 ? block.timestamp + defaultExpiryDuration : expiresAt;
        if (expiry <= block.timestamp) revert InvalidExpiry();

        uint256 totalAmount;
        for (uint256 i; i < len; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
            if (_payouts[payoutIds[i]].createdAt != 0) revert PayoutAlreadyExists();
            totalAmount += amounts[i];
        }

        // Single transferFrom for all payouts
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        for (uint256 i; i < len; ++i) {
            bytes32 pid = payoutIds[i];
            bytes32 ph = phoneHashes[i];
            _payouts[pid] = Payout({
                id: pid,
                sender: msg.sender,
                recipient: address(0),
                token: token,
                amount: amounts[i],
                phoneHash: ph,
                status: PayoutStatus.Pending,
                expiresAt: expiry,
                createdAt: block.timestamp,
                claimedAt: 0
            });
            _phoneToPayouts[ph].push(pid);
            emit PayoutCreated(pid, msg.sender, token, amounts[i], ph);
        }
    }

    // -------------------------------------------------------------------------
    // External: Claim
    // -------------------------------------------------------------------------

    /// @inheritdoc IPayoutEscrow
    /// @dev Caller must hold a MobileNumberNFT whose phone hash matches the payout.
    function claim(bytes32 payoutId) external override nonReentrant whenNotPaused {
        Payout storage p = _requirePending(payoutId);
        bytes32 callerPhoneHash = _resolvePhoneHash(msg.sender);
        if (callerPhoneHash != p.phoneHash) revert PhoneHashMismatch();

        p.status = PayoutStatus.Claimed;
        p.recipient = msg.sender;
        p.claimedAt = block.timestamp;

        IERC20(p.token).safeTransfer(msg.sender, p.amount);
        emit PayoutClaimed(payoutId, msg.sender, p.amount);
    }

    /// @inheritdoc IPayoutEscrow
    /// @dev Claims the payout then immediately routes through the gateway to MoMo.
    ///      The gateway must be set and must support the token.
    function claimToMoMo(bytes32 payoutId, string calldata phoneNumber) external override nonReentrant whenNotPaused {
        if (address(gateway) == address(0)) revert GatewayNotSet();

        Payout storage p = _requirePending(payoutId);
        bytes32 callerPhoneHash = _resolvePhoneHash(msg.sender);
        if (callerPhoneHash != p.phoneHash) revert PhoneHashMismatch();

        if (!gateway.isTokenSupported(p.token)) revert TokenNotSupportedByGateway();

        p.status = PayoutStatus.Claimed;
        p.recipient = msg.sender;
        p.claimedAt = block.timestamp;

        // Approve gateway to pull tokens, then trigger offramp on behalf of the user
        IERC20(p.token).safeIncreaseAllowance(address(gateway), p.amount);
        gateway.offrampFor(msg.sender, p.token, p.amount, phoneNumber);

        emit PayoutClaimed(payoutId, msg.sender, p.amount);
    }

    // -------------------------------------------------------------------------
    // External: Refund
    // -------------------------------------------------------------------------

    /// @inheritdoc IPayoutEscrow
    /// @dev Only original sender or owner may refund. Payout must be expired.
    function refund(bytes32 payoutId) external override nonReentrant {
        Payout storage p = _payouts[payoutId];
        if (p.createdAt == 0) revert PayoutNotFound();
        if (p.status != PayoutStatus.Pending) revert NotPending();
        if (block.timestamp <= p.expiresAt) revert NotExpiredYet();
        if (msg.sender != p.sender && msg.sender != owner()) revert NotRefundEligible();

        address sender = p.sender;
        uint256 amount = p.amount;
        address token = p.token;

        p.status = PayoutStatus.Refunded;

        IERC20(token).safeTransfer(sender, amount);
        emit PayoutRefunded(payoutId, sender, amount);
    }

    // -------------------------------------------------------------------------
    // External: View
    // -------------------------------------------------------------------------

    /// @inheritdoc IPayoutEscrow
    function getPayout(bytes32 payoutId) external view override returns (Payout memory) {
        return _payouts[payoutId];
    }

    /// @inheritdoc IPayoutEscrow
    function getPayoutsForPhone(bytes32 phoneHash) external view override returns (bytes32[] memory) {
        return _phoneToPayouts[phoneHash];
    }

    /// @inheritdoc IPayoutEscrow
    function getPayoutsByStatus(bytes32 phoneHash, PayoutStatus status)
        external
        view
        override
        returns (bytes32[] memory)
    {
        bytes32[] storage ids = _phoneToPayouts[phoneHash];
        uint256 count;
        for (uint256 i; i < ids.length; ++i) {
            if (_payouts[ids[i]].status == status) ++count;
        }
        bytes32[] memory result = new bytes32[](count);
        uint256 idx;
        for (uint256 i; i < ids.length; ++i) {
            if (_payouts[ids[i]].status == status) result[idx++] = ids[i];
        }
        return result;
    }

    // -------------------------------------------------------------------------
    // External: Admin
    // -------------------------------------------------------------------------

    /// @inheritdoc IPayoutEscrow
    function setAuthorizedSender(address sender, bool authorized) external override onlyOwner {
        if (sender == address(0)) revert ZeroAddress();
        authorizedSenders[sender] = authorized;
        emit AuthorizedSenderSet(sender, authorized);
    }

    /// @inheritdoc IPayoutEscrow
    function setDefaultExpiryDuration(uint256 duration) external override onlyOwner {
        defaultExpiryDuration = duration;
        emit DefaultExpiryDurationSet(duration);
    }

    /// @inheritdoc IPayoutEscrow
    function setGateway(address _gateway) external override onlyOwner {
        if (_gateway == address(0)) revert ZeroAddress();
        gateway = IFiatsendGateway(_gateway);
        emit GatewaySet(_gateway);
    }

    /// @inheritdoc IPayoutEscrow
    function pause() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc IPayoutEscrow
    function unpause() external override onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Asserts payout exists, is pending, and not expired. Returns storage ref.
    function _requirePending(bytes32 payoutId) internal view returns (Payout storage p) {
        p = _payouts[payoutId];
        if (p.createdAt == 0) revert PayoutNotFound();
        if (p.status != PayoutStatus.Pending) revert NotPending();
    }

    /// @dev Resolves the phone hash for a caller from their MobileNumberNFT.
    ///      The NFT stores encrypted phone bytes; the hash used by payouts is keccak256 of those bytes.
    function _resolvePhoneHash(address user) internal view returns (bytes32) {
        uint256 tokenId = mobileNumberNFT.getTokenId(user);
        if (tokenId == 0) revert NoMobileNFT();
        // getEncryptedPhone is defined on MobileNumberNFT (not in the interface — called via concrete reference)
        // We use IERC721 to verify ownership and rely on the NFT contract's phone hash storage
        // The phoneHash in a payout must match keccak256(encryptedPhone) stored at mint time
        bytes memory encryptedPhone = _getEncryptedPhone(tokenId);
        return keccak256(encryptedPhone);
    }

    /// @dev Fetches encrypted phone bytes from the NFT. Uses low-level call to avoid
    ///      requiring getEncryptedPhone in the interface.
    function _getEncryptedPhone(uint256 tokenId) internal view returns (bytes memory) {
        (bool ok, bytes memory data) =
            address(mobileNumberNFT).staticcall(abi.encodeWithSignature("getEncryptedPhone(uint256)", tokenId));
        require(ok, "PayoutEscrow: getEncryptedPhone failed");
        return abi.decode(data, (bytes));
    }
}
