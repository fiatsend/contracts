// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MobileNumberNFT} from "../src/identity/MobileNumberNFT.sol";

contract MobileNumberNFTTest is Test {
    MobileNumberNFT public nft;

    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public minter = makeAddr("minter");

    bytes public phone1 = bytes("encrypted_phone_1");
    bytes public phone2 = bytes("encrypted_phone_2");
    string public countryGH = "GH";

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.prank(owner);
        nft = new MobileNumberNFT("https://api.fiatsend.com/identity/");
    }

    // -------------------------------------------------------------------------
    // Deployment
    // -------------------------------------------------------------------------

    function test_Deployment() public view {
        assertEq(nft.name(), "Fiatsend Identity");
        assertEq(nft.symbol(), "FSID");
        assertEq(nft.owner(), owner);
    }

    // -------------------------------------------------------------------------
    // Register Mobile
    // -------------------------------------------------------------------------

    function test_RegisterMobile_Success() public {
        vm.prank(user1);
        nft.registerMobile(phone1, countryGH);

        assertEq(nft.balanceOf(user1), 1);
        uint256 tokenId = nft.getTokenId(user1);
        assertEq(tokenId, 1);
        assertEq(nft.getKYCLevel(tokenId), 0);
        assertEq(nft.getCountryCode(tokenId), countryGH);
    }

    function test_RegisterMobile_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit MobileNumberNFT.MobileNumberRegistered(user1, 1, countryGH);

        vm.prank(user1);
        nft.registerMobile(phone1, countryGH);
    }

    function test_RegisterMobile_RevertIfAlreadyRegistered() public {
        vm.prank(user1);
        nft.registerMobile(phone1, countryGH);

        vm.prank(user1);
        vm.expectRevert(MobileNumberNFT.AlreadyRegistered.selector);
        nft.registerMobile(phone2, countryGH);
    }

    function test_RegisterMobile_RevertIfPhoneDuplicate() public {
        vm.prank(user1);
        nft.registerMobile(phone1, countryGH);

        vm.prank(user2);
        vm.expectRevert(MobileNumberNFT.PhoneAlreadyRegistered.selector);
        nft.registerMobile(phone1, countryGH);
    }

    // -------------------------------------------------------------------------
    // KYC Level
    // -------------------------------------------------------------------------

    function test_UpdateKYCLevel_ByOwner() public {
        vm.prank(user1);
        nft.registerMobile(phone1, countryGH);

        uint256 tokenId = nft.getTokenId(user1);

        vm.prank(owner);
        nft.updateKYCLevel(tokenId, 1);

        assertEq(nft.getKYCLevel(tokenId), 1);
        assertEq(nft.getKYCLevelByAddress(user1), 1);
    }

    function test_UpdateKYCLevel_ByAuthorizedMinter() public {
        vm.prank(owner);
        nft.setAuthorizedMinter(minter, true);

        vm.prank(user1);
        nft.registerMobile(phone1, countryGH);

        uint256 tokenId = nft.getTokenId(user1);

        vm.prank(minter);
        nft.updateKYCLevel(tokenId, 2);

        assertEq(nft.getKYCLevel(tokenId), 2);
    }

    function test_UpdateKYCLevel_RevertUnauthorized() public {
        vm.prank(user1);
        nft.registerMobile(phone1, countryGH);

        uint256 tokenId = nft.getTokenId(user1);

        vm.prank(user2);
        vm.expectRevert(MobileNumberNFT.NotAuthorized.selector);
        nft.updateKYCLevel(tokenId, 1);
    }

    function test_UpdateKYCLevel_RevertInvalidLevel() public {
        vm.prank(user1);
        nft.registerMobile(phone1, countryGH);

        uint256 tokenId = nft.getTokenId(user1);

        vm.prank(owner);
        vm.expectRevert(MobileNumberNFT.InvalidKYCLevel.selector);
        nft.updateKYCLevel(tokenId, 3);
    }

    // -------------------------------------------------------------------------
    // Soulbound — Transfer blocking
    // -------------------------------------------------------------------------

    function test_Transfer_Reverts() public {
        vm.prank(user1);
        nft.registerMobile(phone1, countryGH);

        uint256 tokenId = nft.getTokenId(user1);

        vm.prank(user1);
        vm.expectRevert(MobileNumberNFT.TransferNotAllowed.selector);
        nft.transferFrom(user1, user2, tokenId);
    }

    // -------------------------------------------------------------------------
    // Phone lookup
    // -------------------------------------------------------------------------

    function test_GetTokenIdByPhone() public {
        vm.prank(user1);
        nft.registerMobile(phone1, countryGH);

        uint256 tokenId = nft.getTokenIdByPhone(phone1);
        assertEq(tokenId, nft.getTokenId(user1));
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function test_SetAuthorizedMinter_RevertNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        nft.setAuthorizedMinter(minter, true);
    }

    function test_SetAuthorizedMinter_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MobileNumberNFT.ZeroAddress.selector);
        nft.setAuthorizedMinter(address(0), true);
    }

    function test_SetBaseURI() public {
        vm.prank(owner);
        nft.setBaseURI("https://new-uri.com/");

        vm.prank(user1);
        nft.registerMobile(phone1, countryGH);

        // token URI should use new base
        uint256 tokenId = nft.getTokenId(user1);
        assertGt(tokenId, 0);
    }
}
