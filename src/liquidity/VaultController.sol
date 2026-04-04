// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "../interfaces/IVault.sol";

/// @title VaultController
/// @notice Passive yield vault for stablecoin deposits.
///         Yield accrues linearly based on an annual rate (basis points).
///         Formula: yield = (balance * annualYieldRate * timeElapsed) / (365 days * 10000)
contract VaultController is Ownable, ReentrancyGuard, IVault {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error BelowMinDeposit();
    error ZeroAmount();
    error InsufficientBalance();
    error NoYieldAvailable();
    error ZeroAddress();
    error InvalidYieldRate();

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant MAX_YIELD_RATE = 5000; // 50% per year maximum (safety cap)

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IERC20 public immutable supportedToken;
    uint256 public override annualYieldRate; // basis points (e.g., 500 = 5%)
    uint256 public minDeposit;
    uint256 public totalDeposited;

    mapping(address => VaultInfo) private _vaults;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _supportedToken, uint256 _annualYieldRate, uint256 _minDeposit) Ownable(msg.sender) {
        if (_supportedToken == address(0)) revert ZeroAddress();
        if (_annualYieldRate > MAX_YIELD_RATE) revert InvalidYieldRate();
        supportedToken = IERC20(_supportedToken);
        annualYieldRate = _annualYieldRate;
        minDeposit = _minDeposit;
    }

    // -------------------------------------------------------------------------
    // External: Vault actions
    // -------------------------------------------------------------------------

    /// @inheritdoc IVault
    function deposit(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount < minDeposit) revert BelowMinDeposit();

        _claimAccruedYield(msg.sender);

        supportedToken.safeTransferFrom(msg.sender, address(this), amount);
        VaultInfo storage v = _vaults[msg.sender];
        v.balance += amount;
        totalDeposited += amount;

        if (v.depositedAt == 0) {
            v.depositedAt = block.timestamp;
            v.lastYieldClaim = block.timestamp;
        }

        emit VaultDeposited(msg.sender, amount);
    }

    /// @inheritdoc IVault
    function withdraw(uint256 amount) external override nonReentrant {
        VaultInfo storage v = _vaults[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (v.balance < amount) revert InsufficientBalance();

        _claimAccruedYield(msg.sender);

        v.balance -= amount;
        totalDeposited -= amount;

        supportedToken.safeTransfer(msg.sender, amount);
        emit VaultWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc IVault
    function claimYield() external override nonReentrant {
        uint256 yield = _calculateYield(msg.sender);
        if (yield == 0) revert NoYieldAvailable();

        _vaults[msg.sender].lastYieldClaim = block.timestamp;
        supportedToken.safeTransfer(msg.sender, yield);

        emit YieldClaimed(msg.sender, yield);
    }

    // -------------------------------------------------------------------------
    // External: Admin
    // -------------------------------------------------------------------------

    /// @inheritdoc IVault
    function setAnnualYieldRate(uint256 rate) external override onlyOwner {
        if (rate > MAX_YIELD_RATE) revert InvalidYieldRate();
        annualYieldRate = rate;
        emit YieldRateUpdated(rate);
    }

    /// @notice Sets the minimum deposit amount (owner only).
    function setMinDeposit(uint256 amount) external onlyOwner {
        minDeposit = amount;
    }

    // -------------------------------------------------------------------------
    // External: View
    // -------------------------------------------------------------------------

    /// @inheritdoc IVault
    function getVault(address user) external view override returns (VaultInfo memory) {
        return _vaults[user];
    }

    /// @inheritdoc IVault
    function calculateYield(address user) external view override returns (uint256) {
        return _calculateYield(user);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _calculateYield(address user) internal view returns (uint256) {
        VaultInfo storage v = _vaults[user];
        if (v.balance == 0 || v.lastYieldClaim == 0) return 0;
        uint256 timeElapsed = block.timestamp - v.lastYieldClaim;
        return (v.balance * annualYieldRate * timeElapsed) / (365 days * 10_000);
    }

    function _claimAccruedYield(address user) internal {
        uint256 yield = _calculateYield(user);
        if (yield > 0) {
            _vaults[user].lastYieldClaim = block.timestamp;
            supportedToken.safeTransfer(user, yield);
            emit YieldClaimed(user, yield);
        }
    }
}
