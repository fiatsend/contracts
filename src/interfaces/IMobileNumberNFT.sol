// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMobileNumberNFT
/// @notice Interface for the soulbound ERC-721 identity NFT tied to mobile numbers
interface IMobileNumberNFT {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a mobile number is registered and NFT minted
    event MobileNumberRegistered(address indexed user, uint256 indexed tokenId, string countryCode);

    /// @notice Emitted when a user's KYC level is updated
    event KYCLevelUpdated(address indexed user, uint256 indexed tokenId, uint8 newLevel);

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the token ID owned by the given address (0 if none)
    function getTokenId(address user) external view returns (uint256);

    /// @notice Returns the token ID associated with an encrypted phone number
    function getTokenIdByPhone(bytes calldata encryptedPhone) external view returns (uint256);

    /// @notice Returns the KYC level for a given token ID
    function getKYCLevel(uint256 tokenId) external view returns (uint8);

    /// @notice Returns the KYC level for a given address
    function getKYCLevelByAddress(address user) external view returns (uint8);

    /// @notice Returns the country code for a given token ID
    function getCountryCode(uint256 tokenId) external view returns (string memory);

    // -------------------------------------------------------------------------
    // State-changing functions
    // -------------------------------------------------------------------------

    /// @notice Mints a soulbound NFT tied to an encrypted phone number
    /// @param encryptedPhone The encrypted phone number bytes
    /// @param countryCode The ISO country code (e.g., "GH")
    function registerMobile(bytes calldata encryptedPhone, string calldata countryCode) external;

    /// @notice Gasless mint using an EIP-712 signature from an authorized minter
    function registerMobileWithSignature(
        address user,
        bytes calldata encryptedPhone,
        string calldata countryCode,
        uint256 deadline,
        bytes calldata signature
    ) external;

    /// @notice Updates the KYC level for a token (only authorized operator)
    function updateKYCLevel(uint256 tokenId, uint8 newLevel) external;

    /// @notice Sets an authorized minter address (owner only)
    function setAuthorizedMinter(address minter, bool authorized) external;

    /// @notice Sets the base URI for token metadata (owner only)
    function setBaseURI(string calldata baseURI) external;
}
