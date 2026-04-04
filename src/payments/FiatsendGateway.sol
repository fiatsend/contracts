// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IFiatsendGateway} from "../interfaces/IFiatsendGateway.sol";
import {IMobileNumberNFT} from "../interfaces/IMobileNumberNFT.sol";
import {GHSFIAT} from "../tokens/GHSFIAT.sol";
import {Withdrawals} from "./Withdrawals.sol";

/// @title FiatsendGateway
/// @notice Core UUPS-upgradeable gateway for onramp/offramp operations.
///         Handles token conversion, KYC gating, fee collection, and daily limits.
///         The `offrampFor` function allows authorized contracts (e.g. PayoutEscrow)
///         to trigger an offramp on behalf of a user in a single transaction.
contract FiatsendGateway is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IFiatsendGateway
{
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error TokenNotSupported();
    error NoMobileNFT();
    error KYCRequired();
    error BelowMinimum();
    error DailyLimitExceeded();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidFeeRate();
    error NotAuthorizedOnramp();
    error NotAuthorizedContract();

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant MAX_FEE_RATE = 1000; // 10% in basis points
    uint256 public constant KYC_THRESHOLD = 500 * 10 ** 18; // KYC required above 500 GHSFIAT

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    GHSFIAT public ghsFiatToken;
    IMobileNumberNFT public mobileNumberNFT;
    Withdrawals public withdrawalsContract;

    address public override protocolTreasury;
    uint256 public override protocolFeeRate; // basis points (e.g., 50 = 0.5%)

    uint256 public minWithdrawAmount;
    uint256 public dailyLimit;

    mapping(address => bool) private _supportedTokens;
    mapping(address => uint256) private _conversionRates;
    mapping(address => bool) private _kycPassed;
    mapping(address => uint256) private _dailyVolume;
    mapping(address => uint256) private _lastResetDay;
    mapping(address => bool) private _authorizedOnrampers;

    /// @notice Contracts authorized to call offrampFor (e.g. PayoutEscrow)
    mapping(address => bool) private _authorizedContracts;

    // -------------------------------------------------------------------------
    // Constructor (disable initializers for proxy safety)
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    /// @notice Initializes the gateway proxy.
    /// @param _ghsFiatToken    The GHSFIAT token address.
    /// @param _mobileNumberNFT The MobileNumberNFT address.
    /// @param _treasury        The protocol treasury address.
    /// @param _feeRate         The initial protocol fee rate in basis points.
    function initialize(address _ghsFiatToken, address _mobileNumberNFT, address _treasury, uint256 _feeRate)
        external
        initializer
    {
        if (_ghsFiatToken == address(0) || _mobileNumberNFT == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        if (_feeRate > MAX_FEE_RATE) revert InvalidFeeRate();

        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        ghsFiatToken = GHSFIAT(_ghsFiatToken);
        mobileNumberNFT = IMobileNumberNFT(_mobileNumberNFT);
        protocolTreasury = _treasury;
        protocolFeeRate = _feeRate;
        minWithdrawAmount = 20 * 10 ** 18; // 20 GHSFIAT
        dailyLimit = 10_000 * 10 ** 18; // 10,000 GHSFIAT
    }

    // -------------------------------------------------------------------------
    // External: Core operations
    // -------------------------------------------------------------------------

    /// @inheritdoc IFiatsendGateway
    function offramp(address token, uint256 amount, string calldata phoneNumber)
        external
        override
        nonReentrant
        whenNotPaused
    {
        if (!_supportedTokens[token]) revert TokenNotSupported();
        if (amount == 0) revert ZeroAmount();
        if (amount < minWithdrawAmount) revert BelowMinimum();
        if (IERC721(address(mobileNumberNFT)).balanceOf(msg.sender) == 0) revert NoMobileNFT();
        if (amount >= KYC_THRESHOLD && !_kycPassed[msg.sender]) revert KYCRequired();

        _checkAndUpdateDailyLimit(msg.sender, amount);
        _executeOfframp(msg.sender, token, amount, phoneNumber);
    }

    /// @notice Triggers an offramp on behalf of a user. Tokens must be pre-approved to this contract.
    /// @dev    Only callable by authorized contracts (e.g. PayoutEscrow).
    ///         The caller is responsible for transferring tokens to this contract first via safeIncreaseAllowance.
    /// @param user        The user whose MoMo number will receive the funds.
    /// @param token       Stablecoin to offramp.
    /// @param amount      Token amount (pre-approved by the calling contract).
    /// @param phoneNumber Destination MoMo phone number.
    function offrampFor(address user, address token, uint256 amount, string calldata phoneNumber)
        external
        nonReentrant
        whenNotPaused
    {
        if (!_authorizedContracts[msg.sender]) revert NotAuthorizedContract();
        if (!_supportedTokens[token]) revert TokenNotSupported();
        if (amount == 0) revert ZeroAmount();
        if (user == address(0)) revert ZeroAddress();

        // Pull tokens from the calling contract (it must have approved this gateway)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _executeOfframp(user, token, amount, phoneNumber);
    }

    /// @inheritdoc IFiatsendGateway
    function onramp(address user, uint256 amount) external override nonReentrant whenNotPaused {
        if (!_authorizedOnrampers[msg.sender] && msg.sender != owner()) revert NotAuthorizedOnramp();
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        ghsFiatToken.mint(user, amount);
        emit OnrampCompleted(user, amount);
    }

    // -------------------------------------------------------------------------
    // External: Admin — Configuration
    // -------------------------------------------------------------------------

    /// @inheritdoc IFiatsendGateway
    function setConversionRate(address token, uint256 rate) external override onlyOwner {
        _conversionRates[token] = rate;
        emit ConversionRateUpdated(token, rate);
    }

    /// @inheritdoc IFiatsendGateway
    function addSupportedToken(address token) external override onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        _supportedTokens[token] = true;
        emit TokenAdded(token);
    }

    /// @inheritdoc IFiatsendGateway
    function removeSupportedToken(address token) external override onlyOwner {
        _supportedTokens[token] = false;
        emit TokenRemoved(token);
    }

    /// @inheritdoc IFiatsendGateway
    function setKYC(address user, bool status) external override onlyOwner {
        if (user == address(0)) revert ZeroAddress();
        _kycPassed[user] = status;
    }

    /// @inheritdoc IFiatsendGateway
    function setProtocolFee(uint256 newFeeRate) external override onlyOwner {
        if (newFeeRate > MAX_FEE_RATE) revert InvalidFeeRate();
        protocolFeeRate = newFeeRate;
    }

    /// @inheritdoc IFiatsendGateway
    function setMinWithdrawAmount(uint256 amount) external override onlyOwner {
        minWithdrawAmount = amount;
    }

    /// @inheritdoc IFiatsendGateway
    function setDailyLimit(uint256 limit) external override onlyOwner {
        dailyLimit = limit;
    }

    /// @notice Sets the Withdrawals contract address (owner only).
    function setWithdrawalsContract(address _withdrawals) external onlyOwner {
        if (_withdrawals == address(0)) revert ZeroAddress();
        withdrawalsContract = Withdrawals(_withdrawals);
    }

    /// @notice Authorizes or deauthorizes an onramper address (owner only).
    function setAuthorizedOnramper(address onramper, bool authorized) external onlyOwner {
        if (onramper == address(0)) revert ZeroAddress();
        _authorizedOnrampers[onramper] = authorized;
    }

    /// @notice Authorizes or deauthorizes a contract to call offrampFor (owner only).
    /// @param contractAddr The contract address (e.g. PayoutEscrow).
    /// @param authorized   True to authorize, false to revoke.
    function setAuthorizedContract(address contractAddr, bool authorized) external onlyOwner {
        if (contractAddr == address(0)) revert ZeroAddress();
        _authorizedContracts[contractAddr] = authorized;
    }

    /// @notice Sets the protocol treasury address (owner only).
    function setProtocolTreasury(address treasury) external onlyOwner {
        if (treasury == address(0)) revert ZeroAddress();
        protocolTreasury = treasury;
    }

    // -------------------------------------------------------------------------
    // External: Admin — Emergency
    // -------------------------------------------------------------------------

    /// @inheritdoc IFiatsendGateway
    function emergencyWithdraw(address token, uint256 amount) external override onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    /// @inheritdoc IFiatsendGateway
    function pause() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc IFiatsendGateway
    function unpause() external override onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // External: View
    // -------------------------------------------------------------------------

    /// @inheritdoc IFiatsendGateway
    function isTokenSupported(address token) external view override returns (bool) {
        return _supportedTokens[token];
    }

    /// @inheritdoc IFiatsendGateway
    function getConversionRate(address token) external view override returns (uint256) {
        return _conversionRates[token];
    }

    /// @inheritdoc IFiatsendGateway
    function isKYCPassed(address user) external view override returns (bool) {
        return _kycPassed[user];
    }

    /// @notice Returns the daily volume used by a user today.
    function getDailyVolume(address user) external view returns (uint256) {
        if (_lastResetDay[user] < block.timestamp / 1 days) return 0;
        return _dailyVolume[user];
    }

    /// @notice Returns whether a contract is authorized to call offrampFor.
    function isAuthorizedContract(address contractAddr) external view returns (bool) {
        return _authorizedContracts[contractAddr];
    }

    // -------------------------------------------------------------------------
    // Internal: Offramp execution
    // -------------------------------------------------------------------------

    /// @dev Core offramp logic shared by offramp() and offrampFor().
    ///      Assumes tokens are already in this contract.
    function _executeOfframp(address user, address token, uint256 amount, string calldata phoneNumber) internal {
        uint256 fee = (amount * protocolFeeRate) / 10_000;
        uint256 netAmount = amount - fee;

        if (fee > 0) {
            IERC20(token).safeTransfer(protocolTreasury, fee);
            emit FeeCollected(token, fee, protocolTreasury);
        }

        address withdrawalsAddr = address(withdrawalsContract);
        IERC20(token).safeTransfer(withdrawalsAddr, netAmount);
        withdrawalsContract.createWithdrawal(user, token, netAmount, fee, 1, phoneNumber);

        emit OfframpInitiated(user, token, amount, fee, phoneNumber);
    }

    // -------------------------------------------------------------------------
    // Internal: Daily limit
    // -------------------------------------------------------------------------

    function _checkAndUpdateDailyLimit(address user, uint256 amount) internal {
        uint256 today = block.timestamp / 1 days;
        if (_lastResetDay[user] < today) {
            _dailyVolume[user] = 0;
            _lastResetDay[user] = today;
        }
        if (_dailyVolume[user] + amount > dailyLimit) revert DailyLimitExceeded();
        _dailyVolume[user] += amount;
    }

    // -------------------------------------------------------------------------
    // Internal: UUPS authorization
    // -------------------------------------------------------------------------

    /// @dev Only the owner can authorize upgrades.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
