// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title GHSFIAT
/// @notice ERC-20 stablecoin pegged to the Ghana Cedi (GHS).
///         Role-based minting/burning. Pausable for emergency stops.
contract GHSFIAT is ERC20, ERC20Burnable, ERC20Pausable, AccessControl {
    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address admin) ERC20("GHS Fiat", "GHSFIAT") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // External: Mint / Burn
    // -------------------------------------------------------------------------

    /// @notice Mints GHSFIAT tokens to a recipient.
    /// @param to The recipient address.
    /// @param amount The amount to mint (18 decimals).
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }

    // -------------------------------------------------------------------------
    // External: Pause / Unpause
    // -------------------------------------------------------------------------

    /// @notice Pauses all token transfers.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses all token transfers.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Internal: Hook resolution for multiple inheritance
    // -------------------------------------------------------------------------

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, value);
    }
}
