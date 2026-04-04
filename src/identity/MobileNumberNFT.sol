// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IMobileNumberNFT} from "../interfaces/IMobileNumberNFT.sol";

/// @title MobileNumberNFT
/// @notice Soulbound ERC-721 identity NFT tied to an encrypted phone number.
///         One NFT per user. Non-transferable after mint. Supports KYC tiers.
contract MobileNumberNFT is ERC721Enumerable, EIP712, Ownable, IMobileNumberNFT {
    using ECDSA for bytes32;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error AlreadyRegistered();
    error PhoneAlreadyRegistered();
    error NotAuthorized();
    error InvalidKYCLevel();
    error TransferNotAllowed();
    error SignatureExpired();
    error InvalidSignature();
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    bytes32 private constant REGISTER_TYPEHASH = keccak256(
        "RegisterMobile(address user,bytes encryptedPhone,string countryCode,uint256 deadline,uint256 nonce)"
    );

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    uint256 private _tokenIdCounter;
    string private _baseTokenURI;

    /// @notice Mapping from address to token ID (0 means none)
    mapping(address => uint256) private _addressToTokenId;

    /// @notice Mapping from encrypted phone hash to token ID
    mapping(bytes32 => uint256) private _phoneHashToTokenId;

    /// @notice KYC level per token ID (0 = unverified, 1 = basic, 2 = full)
    mapping(uint256 => uint8) private _kycLevels;

    /// @notice Country code per token ID
    mapping(uint256 => string) private _countryCodes;

    /// @notice Encrypted phone bytes per token ID
    mapping(uint256 => bytes) private _encryptedPhones;

    /// @notice Authorized minters (can call registerMobileWithSignature)
    mapping(address => bool) private _authorizedMinters;

    /// @notice Nonces for EIP-712 replay protection
    mapping(address => uint256) private _nonces;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(string memory baseURI) ERC721("Fiatsend Identity", "FSID") EIP712("MobileNumberNFT", "1") Ownable(msg.sender) {
        _baseTokenURI = baseURI;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyAuthorizedMinter() {
        if (!_authorizedMinters[msg.sender] && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    // -------------------------------------------------------------------------
    // External: Registration
    // -------------------------------------------------------------------------

    /// @inheritdoc IMobileNumberNFT
    function registerMobile(bytes calldata encryptedPhone, string calldata countryCode) external {
        _mintIdentity(msg.sender, encryptedPhone, countryCode);
    }

    /// @inheritdoc IMobileNumberNFT
    function registerMobileWithSignature(
        address user,
        bytes calldata encryptedPhone,
        string calldata countryCode,
        uint256 deadline,
        bytes calldata signature
    ) external onlyAuthorizedMinter {
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 structHash = keccak256(
            abi.encode(REGISTER_TYPEHASH, user, keccak256(encryptedPhone), keccak256(bytes(countryCode)), deadline, _nonces[user]++)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(signature);
        if (signer != user) revert InvalidSignature();

        _mintIdentity(user, encryptedPhone, countryCode);
    }

    // -------------------------------------------------------------------------
    // External: KYC
    // -------------------------------------------------------------------------

    /// @inheritdoc IMobileNumberNFT
    function updateKYCLevel(uint256 tokenId, uint8 newLevel) external onlyAuthorizedMinter {
        if (newLevel > 2) revert InvalidKYCLevel();
        _kycLevels[tokenId] = newLevel;
        address tokenOwner = ownerOf(tokenId);
        emit KYCLevelUpdated(tokenOwner, tokenId, newLevel);
    }

    // -------------------------------------------------------------------------
    // External: Admin
    // -------------------------------------------------------------------------

    /// @inheritdoc IMobileNumberNFT
    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        _authorizedMinters[minter] = authorized;
    }

    /// @inheritdoc IMobileNumberNFT
    function setBaseURI(string calldata baseURI) external onlyOwner {
        _baseTokenURI = baseURI;
    }

    // -------------------------------------------------------------------------
    // External: View
    // -------------------------------------------------------------------------

    /// @inheritdoc IMobileNumberNFT
    function getTokenId(address user) external view returns (uint256) {
        return _addressToTokenId[user];
    }

    /// @inheritdoc IMobileNumberNFT
    function getTokenIdByPhone(bytes calldata encryptedPhone) external view returns (uint256) {
        return _phoneHashToTokenId[keccak256(encryptedPhone)];
    }

    /// @inheritdoc IMobileNumberNFT
    function getKYCLevel(uint256 tokenId) external view returns (uint8) {
        return _kycLevels[tokenId];
    }

    /// @inheritdoc IMobileNumberNFT
    function getKYCLevelByAddress(address user) external view returns (uint8) {
        return _kycLevels[_addressToTokenId[user]];
    }

    /// @inheritdoc IMobileNumberNFT
    function getCountryCode(uint256 tokenId) external view returns (string memory) {
        return _countryCodes[tokenId];
    }

    /// @notice Returns the nonce for a user (used for EIP-712 replay protection)
    function nonces(address user) external view returns (uint256) {
        return _nonces[user];
    }

    /// @notice Returns the encrypted phone bytes for a token
    function getEncryptedPhone(uint256 tokenId) external view returns (bytes memory) {
        return _encryptedPhones[tokenId];
    }

    // -------------------------------------------------------------------------
    // Internal: Mint
    // -------------------------------------------------------------------------

    function _mintIdentity(address user, bytes calldata encryptedPhone, string calldata countryCode) internal {
        if (_addressToTokenId[user] != 0) revert AlreadyRegistered();
        bytes32 phoneHash = keccak256(encryptedPhone);
        if (_phoneHashToTokenId[phoneHash] != 0) revert PhoneAlreadyRegistered();

        uint256 tokenId = ++_tokenIdCounter;
        _addressToTokenId[user] = tokenId;
        _phoneHashToTokenId[phoneHash] = tokenId;
        _encryptedPhones[tokenId] = encryptedPhone;
        _countryCodes[tokenId] = countryCode;
        _kycLevels[tokenId] = 0;

        _safeMint(user, tokenId);
        emit MobileNumberRegistered(user, tokenId, countryCode);
    }

    // -------------------------------------------------------------------------
    // Internal: Soulbound — block transfers (allow only mint/burn)
    // -------------------------------------------------------------------------

    /// @dev OZ v5: override _update to enforce soulbound. Allow mint (from=0) and burn (to=0).
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721Enumerable) returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert TransferNotAllowed();
        return super._update(to, tokenId, auth);
    }

    // -------------------------------------------------------------------------
    // Internal: Base URI
    // -------------------------------------------------------------------------

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    // -------------------------------------------------------------------------
    // Internal: ERC721Enumerable hook
    // -------------------------------------------------------------------------

    function _increaseBalance(address account, uint128 value) internal override(ERC721Enumerable) {
        super._increaseBalance(account, value);
    }
}
