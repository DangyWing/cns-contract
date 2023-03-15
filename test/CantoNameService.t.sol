// // SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {CantoNameService} from "../src/CantoNameService.sol";
import {console2} from "forge-std/console2.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {ERC721TokenReceiver} from "solmate/src/tokens/ERC721.sol";
import {fromDaysWadUnsafe, toDaysWadUnsafe, toWadUnsafe} from "solmate/src/utils/SignedWadMath.sol";
import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {LibString} from "src/lib/LibString.sol";
import {LibLinearVRGDA} from "src/lib/LibLinearVRGDA.sol";
import {MockLinearVRGDA} from "test/mocks/MockLinearVRGDA.sol";
import {DelegationRegistry} from "./mocks/DelegationRegistry.sol";
import {Turnstile} from "./mocks/Turnstile.sol";

contract CNSTest is Test {
    CantoNameService cns;
    DelegationRegistry reg;
    MockLinearVRGDA vrgda;
    Turnstile turnstile;

    using ECDSA for bytes32;
    using ECDSA for bytes;

    uint256 testTokenId;
    uint256 price;

    uint256 SIGNER_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address SIGNER_ADDRESS = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address OWNER_ADDRESS = vm.addr(666);
    address DEAD = 0x000000000000000000000000000000000000dEaD;
    address ALIVE = 0x0000000000000000000000000000000000000042;
    address TURNSTILE_DEPLOYER = 0x0000000000000000000000000000000000000666;
    address FROM_ADDRESS = 0x2eB5e5713A874786af6Da95f6E4DEaCEdb5dC246;

    /* **** NOTE ****
    COMMENT OUT in CantoNameservice.sol turnstile.register(tx.origin); in constructor for tests.
    todo: fix testing so that we deploy Turnstile to the prod Turnstile address
    */

    string NAME = "test";
    string NAME_WITH_WHITESPACE = " ";
    string NAME_WITH_NO_LENGTH = "";

    bytes SIGNATURE = signMessageWithPK(FROM_ADDRESS, NAME);
    bytes WHITESPACE_SIGNATURE = signMessageWithPK(FROM_ADDRESS, NAME_WITH_WHITESPACE);
    bytes EMPTY_SIGNATURE = signMessageWithPK(FROM_ADDRESS, NAME_WITH_NO_LENGTH);
    bytes32 MSG_HASH = generateHashForAddressAndName(FROM_ADDRESS, NAME);

    function setUp() public {
        vm.startPrank(TURNSTILE_DEPLOYER);
        turnstile = new Turnstile();
        vm.stopPrank();

        vm.deal(FROM_ADDRESS, 1000e18);
        vm.deal(DEAD, 1000e18);

        vm.startPrank(OWNER_ADDRESS, OWNER_ADDRESS);
        vrgda = new MockLinearVRGDA();
        reg = new DelegationRegistry();

        cns = new CantoNameService(address(reg), address(SIGNER_ADDRESS));

        cns.setStatus(1);
        int256 baseTargetDecayPercent = 0.42e18;

        int256[] memory tempTargetPrices = new int256[](6);
        int256[] memory tempPriceDecays = new int256[](6);
        int256[] memory tempBasePerTimeUnits = new int256[](6);

        tempTargetPrices[0] = 200e18;
        tempTargetPrices[1] = 100e18;
        tempTargetPrices[2] = 50e18;
        tempTargetPrices[3] = 20e18;
        tempTargetPrices[4] = 15e18;
        tempTargetPrices[5] = 10e18;

        tempBasePerTimeUnits[0] = 0.5e18;
        tempBasePerTimeUnits[1] = 1e18;
        tempBasePerTimeUnits[2] = 3e18;
        tempBasePerTimeUnits[3] = 4e18;
        tempBasePerTimeUnits[4] = 5e18;
        tempBasePerTimeUnits[5] = 15e18;

        for (uint256 i = 0; i < 6; i++) {
            tempPriceDecays[i] = baseTargetDecayPercent;
        }

        cns.setupVRGDAs(tempTargetPrices, tempPriceDecays, tempBasePerTimeUnits, 6);

        testTokenId = cns.nameToId("test");

        cns.setSignerAddress(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);

        price = cns.priceName("test");

        vm.stopPrank();
    }

    function testBurnAndMintWithRegisterAfterExpiry() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        vm.stopPrank();

        uint256 tokenId = cns.nameToId(NAME);
        address preOwner = cns.ownerOf(tokenId);
        assertEq(preOwner, FROM_ADDRESS);

        vm.warp(block.timestamp + 420 days);

        bytes memory DEAD_SIG = signMessageWithPK(DEAD, NAME);

        vm.startPrank(DEAD);
        cns.registerName{value: price}(NAME, 1, DEAD_SIG);
        address postOwner = cns.ownerOf(tokenId);
        assertEq(postOwner, DEAD);
        vm.stopPrank();
    }

    function testTokenIsAvailableAfterExpiryAndGrace() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        vm.stopPrank();

        vm.warp(block.timestamp + 366 days);

        uint256 tokenId = cns.nameToId(NAME);

        assertTrue(cns.isNameAvailable(tokenId));
    }

    function testTokenIsUnavailableInGracePeriod() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        vm.stopPrank();
        vm.warp(block.timestamp + 375);
        uint256 tokenId = cns.nameToId(NAME);
        assertTrue(!cns.isNameAvailable(tokenId));
    }

    function testManyNameRightsHolders() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);

        uint256 tokenId = cns.nameToId(NAME);

        reg.delegateForToken(DEAD, address(cns), tokenId, true);
        reg.delegateForToken(ALIVE, address(cns), tokenId, true);

        address[] memory rightsHolders = cns.nameRightsHolders(tokenId, FROM_ADDRESS);

        console2.log("rightsHolders 1", rightsHolders[0]);
        console2.log("rightsHolders 2", rightsHolders[1]);
        console2.log("rightsHolders 3", rightsHolders[2]);

        assertEq(rightsHolders[0], FROM_ADDRESS);
        assertEq(rightsHolders[1], DEAD);
        assertEq(rightsHolders[2], ALIVE);
        vm.stopPrank();
    }

    function testDelegateToken() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        reg.delegateForToken(DEAD, address(cns), tokenId, true);

        assertTrue(reg.checkDelegateForToken(DEAD, FROM_ADDRESS, address(cns), tokenId));

        bool isRightsHolder = cns.isAddressRightsHolder(DEAD, tokenId, FROM_ADDRESS);

        assertTrue(isRightsHolder);
        vm.stopPrank();
    }

    function testSetPrimaryAsDelegate() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        reg.delegateForToken(DEAD, address(cns), tokenId, true);
        vm.stopPrank();

        vm.startPrank(DEAD);
        cns.setPrimaryName(tokenId, FROM_ADDRESS);

        vm.stopPrank();
        assertEq(cns.getPrimary(DEAD), NAME);
    }

    function testRevertSetPrimaryAsVaultWhenDelegated() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        reg.delegateForToken(DEAD, address(cns), tokenId, true);

        vm.expectRevert(CantoNameService.NotRightsHolder.selector);
        cns.setPrimaryName(tokenId, FROM_ADDRESS);
        vm.stopPrank();
    }

    function testSetPrimaryAsVaultWhenDelegated() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        reg.delegateForToken(DEAD, address(cns), tokenId, true);

        cns.setPrimaryName(tokenId, address(0x0));
        vm.stopPrank();
    }

    function testRenewNameAsDelegate() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        uint256 expiry = cns.expiry(tokenId);

        assertEq(expiry, block.timestamp + 365 days);

        uint256 namePriceNew = cns.priceName(NAME);
        reg.delegateForToken(DEAD, address(cns), tokenId, true);
        vm.stopPrank();

        vm.startPrank(DEAD);
        cns.renewName{value: namePriceNew}(tokenId, 1);

        uint256 newExpiry = cns.expiry(tokenId);
        assertEq(newExpiry, block.timestamp + 730 days);
        assertTrue(cns.isAddressRightsHolder(DEAD, testTokenId, FROM_ADDRESS));
        vm.stopPrank();
    }

    function testRenewNameAsDelegateExpiryTimeAccurate() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        uint256 expiry = cns.expiry(tokenId);

        assertEq(expiry, block.timestamp + 365 days);

        uint256 namePriceNew = cns.priceName(NAME);

        cns.renewName{value: namePriceNew}(tokenId, 1);

        uint256 newExpiry = cns.expiry(tokenId);
        assertEq(newExpiry, expiry + 365 days);
        assertTrue(cns.isAddressRightsHolder(FROM_ADDRESS, testTokenId, address(0x0)));
        vm.stopPrank();
    }

    function testRenewNameAsDelegateExpiryTimeAccurateWithGrace() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        uint256 expiry = cns.expiry(tokenId);

        assertEq(expiry, block.timestamp + 365 days);

        // in grace period
        vm.warp(block.timestamp + 377 days);

        uint256 namePriceNew = cns.priceName(NAME);

        cns.renewName{value: namePriceNew}(tokenId, 1);

        uint256 newExpiry = cns.expiry(tokenId);
        assertEq(newExpiry, block.timestamp + 365 days);
        assertTrue(cns.isAddressRightsHolder(FROM_ADDRESS, testTokenId, address(0x0)));
        vm.stopPrank();
    }

    function testRenewNameAsVault() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        uint256 expiry = cns.expiry(tokenId);

        assertEq(expiry, block.timestamp + 365 days);

        uint256 namePriceNew = cns.priceName(NAME);
        reg.delegateForToken(DEAD, address(cns), tokenId, true);
        vm.stopPrank();

        vm.startPrank(FROM_ADDRESS);
        cns.renewName{value: namePriceNew}(tokenId, 1);

        uint256 newExpiry = cns.expiry(tokenId);

        assertEq(newExpiry, block.timestamp + 730 days);
        assertTrue(cns.isAddressRightsHolder(DEAD, testTokenId, FROM_ADDRESS));
        assertTrue(cns.isAddressRightsHolder(FROM_ADDRESS, testTokenId, address(0x0)));
        vm.stopPrank();
    }

    function testTargetPricing() public {
        vm.startPrank(OWNER_ADDRESS);

        uint256 lengthToSetup = 1;
        int256 targetPrice = 200e18;
        int256 priceDecayPercent = 0.42e18;
        int256 perTimeUnit = 0.5e18;

        vrgda.setupSingleVRGDA(lengthToSetup, targetPrice, priceDecayPercent, perTimeUnit);

        // Warp to the target sale time so that the VRGDA price equals the target price.
        vm.warp(block.timestamp + fromDaysWadUnsafe(vrgda.getTargetSaleTime(1e18, lengthToSetup)));

        uint256 cost = LibLinearVRGDA.getVRGDAPrice(
            targetPrice, priceDecayPercent, perTimeUnit, toDaysWadUnsafe(block.timestamp), 0
        );

        vm.stopPrank();

        assertRelApproxEq(cost, uint256(targetPrice), 0.00001e18);
    }

    function testPricingBasic() public {
        uint256 lengthToSetup = 1;
        int256 targetPrice = 69.42e18;
        int256 priceDecayPercent = 0.31e18;
        int256 perTimeUnit = 2e18;

        vrgda.setupSingleVRGDA(lengthToSetup, targetPrice, priceDecayPercent, perTimeUnit);

        // Our VRGDA targets this number of mints at the given time.
        uint256 timeDelta = 120 days;
        uint256 numMint = 239;

        vm.warp(block.timestamp + timeDelta);

        uint256 cost = LibLinearVRGDA.getVRGDAPrice(
            targetPrice, priceDecayPercent, perTimeUnit, toDaysWadUnsafe(block.timestamp), numMint
        );
        assertRelApproxEq(cost, uint256(targetPrice), 0.00001e18);
    }

    function testAlwaysTargetPriceInRightConditions(uint256 sold) public {
        uint256 lengthToSetup = 1;
        int256 targetPrice = 69.42e18;
        int256 priceDecayPercent = 0.31e18;
        int256 perTimeUnit = 2e18;

        vrgda.setupSingleVRGDA(lengthToSetup, targetPrice, priceDecayPercent, perTimeUnit);

        sold = bound(sold, 0, type(uint128).max);

        uint256 cost = LibLinearVRGDA.getVRGDAPrice(
            targetPrice,
            priceDecayPercent,
            perTimeUnit,
            LibLinearVRGDA.getTargetSaleTime(toWadUnsafe(sold + 1), perTimeUnit),
            sold
        );

        assertRelApproxEq(cost, uint256(targetPrice), 0.00001e18);
    }

    function testStringLength() public {
        string memory _string = "test";
        uint256 length = _stringLength(_string);
        assertEq(length, 4);
    }

    function testTransferTokenClearSenderPrimary() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        cns.setPrimaryName(tokenId, address(0x0));
        string memory prePrimary = cns.getPrimary(FROM_ADDRESS);
        assertEq(prePrimary, NAME);
        cns.transferFrom(FROM_ADDRESS, DEAD, tokenId);
        vm.expectRevert(CantoNameService.NoPrimaryName.selector);

        cns.getPrimary(FROM_ADDRESS);

        assertEq(cns.ownerOf(tokenId), DEAD);
        vm.stopPrank();
    }

    function testNameRightsHolder() public {
        vm.prank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);

        uint256 tokenId = cns.nameToId(NAME);

        bool isRightsHolder = cns.isAddressRightsHolder(FROM_ADDRESS, tokenId, address(0x0));

        assertEq(isRightsHolder, true);
    }

    function testRefundOverpay() public {
        vm.prank(FROM_ADDRESS);
        uint256 registrantBalance = address(FROM_ADDRESS).balance;
        cns.registerName{value: price + 10e18}(NAME, 1, SIGNATURE);

        assertEq(registrantBalance - price, address(FROM_ADDRESS).balance);
    }

    function testApproveToSend() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        assertTrue(cns.isAddressRightsHolder(FROM_ADDRESS, tokenId, address(0x0)));

        cns.approve(DEAD, tokenId);
        vm.stopPrank();

        vm.startPrank(DEAD);
        cns.transferFrom(FROM_ADDRESS, DEAD, tokenId);
        assertEq(cns.ownerOf(tokenId), DEAD);
        vm.stopPrank();
    }

    function testNameRightsHolderExpired() public {
        vm.prank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        assertTrue(cns.isAddressRightsHolder(FROM_ADDRESS, tokenId, address(0x0)));

        vm.warp(block.timestamp + 366 days);

        assertFalse(cns.isAddressRightsHolder(FROM_ADDRESS, tokenId, address(0x0)));
    }

    function testPrimaryNameAfterExpiry() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        cns.setPrimaryName(tokenId, address(0x0));
        vm.stopPrank();

        assertEq(cns.getPrimary(FROM_ADDRESS), NAME);

        string memory primaryNameBefore = cns.getPrimary(FROM_ADDRESS);
        assertEq(primaryNameBefore, NAME);

        vm.warp(block.timestamp + 366 days);
        vm.expectRevert(CantoNameService.NameExpired.selector);
        cns.getPrimary(FROM_ADDRESS);
    }

    function testIsNameExpired() public {
        vm.prank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        assertEq(cns.isNameExpired(tokenId), false);

        vm.warp(block.timestamp + 366 days);

        assertEq(cns.isNameExpired(tokenId), true);
    }

    function testSetupMultipleVRGDAs() public {
        int256 baseTargetDecayPercent = 0.8e18;
        int256 basePerTimeUnit = 10e18;

        int256[] memory tempTargetPrices = new int256[](6);
        int256[] memory tempPriceDecays = new int256[](6);
        int256[] memory tempBasePerTimeUnits = new int256[](6);

        tempTargetPrices[0] = 200e18;
        tempTargetPrices[1] = 100e18;
        tempTargetPrices[2] = 50e18;
        tempTargetPrices[3] = 20e18;
        tempTargetPrices[4] = 15e18;
        tempTargetPrices[5] = 10e18;

        tempBasePerTimeUnits[0] = 0.5e18;
        tempBasePerTimeUnits[1] = 1e18;
        tempBasePerTimeUnits[2] = 3e18;
        tempBasePerTimeUnits[3] = 4e18;
        tempBasePerTimeUnits[4] = 5e18;
        tempBasePerTimeUnits[5] = 15e18;

        for (uint256 i = 0; i < 6; i++) {
            tempPriceDecays[i] = baseTargetDecayPercent;
            tempBasePerTimeUnits[i] = basePerTimeUnit;
        }
        vm.startPrank(OWNER_ADDRESS);
        cns.setupVRGDAs(tempTargetPrices, tempPriceDecays, tempBasePerTimeUnits, 6);
        vm.stopPrank();

        for (uint256 i = 0; i < 6; ++i) {
            (int256 targetPrice, int256 priceDecayPercent,, int256 perTimeUnit, int256 startTime) = cns.vrgdaData(i);

            assertEq(targetPrice, tempTargetPrices[i]);
            assertEq(priceDecayPercent, tempPriceDecays[i]);
            assertEq(perTimeUnit, tempBasePerTimeUnits[i]);
            assertEq(startTime, int256(block.timestamp));
        }
    }

    function testSingleVRGDAAfterMultipleVRGDAs() public {
        int256 baseTargetDecayPercent = 0.8e18;
        int256 basePerTimeUnit = 10e18;

        int256[] memory tempTargetPrices = new int256[](6);
        int256[] memory tempPriceDecays = new int256[](6);
        int256[] memory tempBasePerTimeUnits = new int256[](6);

        tempTargetPrices[0] = 200e18;
        tempTargetPrices[1] = 100e18;
        tempTargetPrices[2] = 50e18;
        tempTargetPrices[3] = 20e18;
        tempTargetPrices[4] = 15e18;
        tempTargetPrices[5] = 10e18;

        tempBasePerTimeUnits[0] = 0.5e18;
        tempBasePerTimeUnits[1] = 1e18;
        tempBasePerTimeUnits[2] = 3e18;
        tempBasePerTimeUnits[3] = 4e18;
        tempBasePerTimeUnits[4] = 5e18;
        tempBasePerTimeUnits[5] = 15e18;

        for (uint256 i = 0; i < 6; i++) {
            tempPriceDecays[i] = baseTargetDecayPercent;
            tempBasePerTimeUnits[i] = basePerTimeUnit;
        }
        vm.startPrank(OWNER_ADDRESS);
        cns.setupVRGDAs(tempTargetPrices, tempPriceDecays, tempBasePerTimeUnits, 6);

        int256 tempTargetPrice = 42e18;
        int256 tempPriceDecay = 0.42e18;
        int256 tempBasePerTimeUnit = 42e18;
        uint256 lengthToSetup = 1;

        cns.setupSingleVRGDA(lengthToSetup, tempTargetPrice, tempPriceDecay, tempBasePerTimeUnit);
        vm.stopPrank();

        (int256 targetPrice, int256 priceDecayPercent,, int256 perTimeUnit, int256 startTime) =
            cns.vrgdaData(lengthToSetup - 1);

        assertEq(targetPrice, tempTargetPrice);
        assertEq(priceDecayPercent, tempPriceDecay);
        assertEq(perTimeUnit, tempBasePerTimeUnit);
        assertEq(startTime, int256(block.timestamp));
    }

    function testSetupVRGDAsRevertDecayTooHigh() public {
        int256 baseTargetDecayPercent = 2e18;
        int256 basePerTimeUnit = 10e18;

        int256[] memory tempTargetPrices = new int256[](2);
        int256[] memory tempPriceDecays = new int256[](2);
        int256[] memory tempBasePerTimeUnits = new int256[](2);

        tempTargetPrices[0] = 200e18;
        tempTargetPrices[1] = 100e18;

        tempBasePerTimeUnits[0] = 0.5e18;
        tempBasePerTimeUnits[1] = 1e18;

        for (uint256 i = 0; i < 2; i++) {
            tempPriceDecays[i] = baseTargetDecayPercent;
            tempBasePerTimeUnits[i] = basePerTimeUnit;
        }
        vm.startPrank(OWNER_ADDRESS);
        vm.expectRevert(CantoNameService.PercentTooHigh.selector);
        cns.setupVRGDAs(tempTargetPrices, tempPriceDecays, tempBasePerTimeUnits, 2);
        vm.stopPrank();
    }

    function testSetupVRGDAsRevertInvalidCount() public {
        int256 baseTargetDecayPercent = 2e18;
        int256 basePerTimeUnit = 10e18;

        int256[] memory tempTargetPrices = new int256[](2);
        int256[] memory tempPriceDecays = new int256[](2);
        int256[] memory tempBasePerTimeUnits = new int256[](2);

        tempTargetPrices[0] = 200e18;
        tempTargetPrices[1] = 100e18;

        tempBasePerTimeUnits[0] = 0.5e18;
        tempBasePerTimeUnits[1] = 1e18;

        for (uint256 i = 0; i < 2; i++) {
            tempPriceDecays[i] = baseTargetDecayPercent;
            tempBasePerTimeUnits[i] = basePerTimeUnit;
        }
        vm.startPrank(OWNER_ADDRESS);
        vm.expectRevert(CantoNameService.InvalidCount.selector);
        cns.setupVRGDAs(tempTargetPrices, tempPriceDecays, tempBasePerTimeUnits, 3);
        vm.stopPrank();
    }

    function testSetupSingleVRGDAEvent() public {
        int256 tempTargetPrice = 200e18;
        int256 tempPriceDecay = 0.4e18;
        int256 tempBasePerTimeUnit = 2e18;

        vm.startPrank(OWNER_ADDRESS);
        vm.expectEmit(true, true, true, true);

        emit SetupVRGDA(1, tempTargetPrice, tempPriceDecay, tempBasePerTimeUnit);

        cns.setupSingleVRGDA(1, tempTargetPrice, tempPriceDecay, tempBasePerTimeUnit);
        vm.stopPrank();
    }

    function testSetupSingleVRGDA() public {
        int256 tempTargetPrice = 200e18;
        int256 tempPriceDecay = 0.4e18;
        int256 tempBasePerTimeUnit = 2e18;

        vm.startPrank(OWNER_ADDRESS);

        cns.setupSingleVRGDA(1, tempTargetPrice, tempPriceDecay, tempBasePerTimeUnit);
        vm.stopPrank();
    }

    event SetupVRGDA(uint256 indexed length, int256 targetPrice, int256 priceDecayPercent, int256 perTimeUnit);

    function testSetupSingleVRGDARevertDecayTooHigh() public {
        int256 tempTargetPrice = 200e18;
        int256 tempPriceDecay = 4e18;
        int256 tempBasePerTimeUnit = 2e18;

        vm.startPrank(OWNER_ADDRESS);
        vm.expectRevert(CantoNameService.PercentTooHigh.selector);
        cns.setupSingleVRGDA(1, tempTargetPrice, tempPriceDecay, tempBasePerTimeUnit);
        vm.stopPrank();
    }

    function testSetupSingleVRGDARevertOnlyOwner() public {
        int256 tempTargetPrice = 200e18;
        int256 tempPriceDecay = 0.4e18;
        int256 tempBasePerTimeUnit = 2e18;

        vm.startPrank(DEAD);
        vm.expectRevert();
        cns.setupSingleVRGDA(1, tempTargetPrice, tempPriceDecay, tempBasePerTimeUnit);
        vm.stopPrank();
    }

    function testRevertSetPrimaryNotRightsHolder() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        vm.stopPrank();

        vm.startPrank(DEAD);
        vm.expectRevert(CantoNameService.NotRightsHolder.selector);
        cns.setPrimaryName(tokenId, address(0x0));
        vm.stopPrank();
    }

    function testSetPrimaryName() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        cns.setPrimaryName(tokenId, address(0x0));
        vm.stopPrank();

        assertEq(cns.getPrimary(FROM_ADDRESS), NAME);
    }

    function testPrimaryNameIdToAddress() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        cns.setPrimaryName(tokenId, address(0x0));
        vm.stopPrank();

        assertEq(cns.currentPrimary(tokenId), FROM_ADDRESS);
    }

    function testClearPrimaryName() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        cns.setPrimaryName(tokenId, address(0x0));

        assertEq(cns.getPrimary(FROM_ADDRESS), NAME);

        cns.clearPrimaryName();
        vm.stopPrank();

        vm.expectRevert(CantoNameService.NoPrimaryName.selector);
        cns.getPrimary(FROM_ADDRESS);
    }

    function testSetBaseURI() public {
        assertEq(cns.contractURI(), "");
        vm.prank(OWNER_ADDRESS);
        cns.setBaseURI("https://canto.network/");

        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        string memory tokenURI = cns.tokenURI(tokenId);

        string memory expectedTokenURI = string(abi.encodePacked("https://canto.network/", LibString.toString(tokenId)));

        assertEq(tokenURI, expectedTokenURI);
        vm.stopPrank();
    }

    function testGetExpiredURI() public {
        assertEq(cns.contractURI(), "");
        vm.startPrank(OWNER_ADDRESS);
        cns.setBaseURI("https://canto.network/");
        cns.setExpiredURI("https://EXPIRED.network/");
        vm.stopPrank();

        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        vm.warp(block.timestamp + 367 days);

        string memory newTokenURI = cns.tokenURI(tokenId);

        string memory expectedTokenURI =
            string(abi.encodePacked("https://EXPIRED.network/", LibString.toString(tokenId)));

        assertEq(newTokenURI, expectedTokenURI);
        vm.stopPrank();
    }

    function testRevertSetBaseURINotOwner() public {
        assertEq(cns.contractURI(), "");
        vm.prank(DEAD);
        vm.expectRevert();
        cns.setBaseURI("https://canto.network/");
    }

    function testTokenURIRevertNameNotRegistered() public {
        vm.startPrank(FROM_ADDRESS);
        vm.expectRevert(CantoNameService.InvalidToken.selector);
        cns.tokenURI(1);
        vm.stopPrank();
    }

    function testSetContractURI() public {
        assertEq(cns.contractURI(), "");
        string memory newURI = "https://canto.network/";
        vm.prank(OWNER_ADDRESS);
        cns.setContractURI(newURI);

        assertEq(cns.contractURI(), newURI);
    }

    function testSetRoyaltyInfo() public {
        vm.startPrank(OWNER_ADDRESS);
        cns.setRoyaltyInfo(DEAD, 4200);
        vm.stopPrank();

        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        (address royaltyRecipient, uint256 royaltyAmount) = cns.royaltyInfo(tokenId, 100e18);
        assertEq(royaltyRecipient, DEAD);
        assertEq(royaltyAmount, 42e18);
        vm.stopPrank();
    }

    function testSetSignerAddress() public {
        vm.startPrank(OWNER_ADDRESS);
        address oldAddress = cns._signerAddress();
        assertEq(oldAddress, SIGNER_ADDRESS);
        cns.setSignerAddress(DEAD);
        vm.stopPrank();

        assertEq(cns._signerAddress(), DEAD);
    }

    function testRemovePrimaryOnTransfer() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        cns.setPrimaryName(tokenId, address(0x0));
        string memory currPrimary = cns.getPrimary(FROM_ADDRESS);

        assertEq(currPrimary, NAME);

        cns.transferFrom(FROM_ADDRESS, OWNER_ADDRESS, tokenId);
        vm.stopPrank();

        vm.expectRevert(CantoNameService.NoPrimaryName.selector);
        cns.getPrimary(FROM_ADDRESS);
    }

    function testRemovePrimaryOnSafeTransfer() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        cns.setPrimaryName(tokenId, address(0x0));
        string memory currPrimary = cns.getPrimary(FROM_ADDRESS);

        assertEq(currPrimary, NAME);

        cns.safeTransferFrom(FROM_ADDRESS, OWNER_ADDRESS, tokenId);
        vm.expectRevert(CantoNameService.NoPrimaryName.selector);
        cns.getPrimary(FROM_ADDRESS);

        vm.stopPrank();
    }

    function testGetNameOwner() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        vm.stopPrank();

        uint256 tokenId = cns.nameToId(NAME);

        assertEq(cns.ownerOf(tokenId), FROM_ADDRESS);
    }

    function testWithdraw() public {
        uint256 ownerBalance = OWNER_ADDRESS.balance;

        vm.prank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);

        vm.prank(OWNER_ADDRESS);
        cns.withdraw();

        assertEq(OWNER_ADDRESS.balance, ownerBalance + price);
    }

    function testWithdrawRevertNoBalance() public {
        vm.prank(OWNER_ADDRESS);
        vm.expectRevert(CantoNameService.NoBalance.selector);
        cns.withdraw();
    }

    function testWithdrawRevertNonOwner() public {
        vm.prank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);

        vm.prank(FROM_ADDRESS);
        vm.expectRevert();
        cns.withdraw();
    }

    function testTransferOwnership() public {
        vm.startPrank(OWNER_ADDRESS);
        cns.transferOwnership(DEAD);
        vm.stopPrank();

        assertEq(cns.owner(), DEAD);
    }

    function testWithdrawRevertFailedWithdraw() public {
        address withdrawFailAddress = address(new MockFailWithdraw());

        vm.startPrank(OWNER_ADDRESS);
        cns.transferOwnership(withdrawFailAddress);
        vm.stopPrank();

        vm.prank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        assertEq(cns.owner(), withdrawFailAddress);

        vm.startPrank(withdrawFailAddress);
        vm.expectRevert(CantoNameService.WithdrawFailed.selector);
        cns.withdraw();
        vm.stopPrank();
    }

    function testSupportInterface() public {
        bool doesSupport = cns.supportsInterface(0x01ffc9a7);
        assertEq(doesSupport, true);
    }

    function invariantMetadata() public {
        assertEq(cns.name(), "Canto Name Service");
        assertEq(cns.symbol(), "CNS");
    }

    function testOwnerAddress() public {
        assertEq(cns.owner(), OWNER_ADDRESS);
    }

    function testRegisterName() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        vm.stopPrank();
    }

    function testRevertRegisterNameInvalidPayment() public {
        vm.startPrank(FROM_ADDRESS);
        vm.expectRevert(CantoNameService.InvalidPayment.selector);
        cns.registerName{value: 1 wei}(NAME, 1, SIGNATURE);
        vm.stopPrank();
    }

    function testApproveAll() public {
        address target = address(0xBEEF);

        cns.setApprovalForAll(target, true);

        assertTrue(cns.isApprovedForAll(address(this), target));
    }

    function generateHashForAddressAndName(address _address, string memory _name) public pure returns (bytes32) {
        bytes32 hash = keccak256(abi.encodePacked(_address, _name));
        return ECDSA.toEthSignedMessageHash(hash);
    }

    function _verifySignature(string calldata _name, bytes calldata signature) public view returns (bool) {
        bytes32 hash = keccak256(abi.encodePacked(msg.sender, _name));
        bytes32 ethSignedMessageHash = ECDSA.toEthSignedMessageHash(hash);
        return SIGNER_ADDRESS == ECDSA.recover(ethSignedMessageHash, signature);
    }

    function signMessageWithPK(address _address, string memory _name) public returns (bytes memory) {
        bytes32 msgHash = generateHashForAddressAndName(_address, _name);
        vm.startPrank(SIGNER_ADDRESS);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, msgHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        vm.stopPrank();
        return signature;
    }

    function testSignMessageWithPK() public {
        address from = address(0x2eB5e5713A874786af6Da95f6E4DEaCEdb5dC246);
        bytes memory signature = signMessageWithPK(from, "test");

        bytes32 msgHash = generateHashForAddressAndName(from, NAME);

        address recoveredAddress = this.recover(msgHash, signature);

        assertEq(recoveredAddress, SIGNER_ADDRESS);
    }

    function testTransferFrom() public {
        address from = address(0x2eB5e5713A874786af6Da95f6E4DEaCEdb5dC246);
        address to = address(0x50664edE715e131F584D3E7EaAbd7818Bb20A068);

        vm.prank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        cns.transferFrom(from, to, testTokenId);

        assertEq(cns.ownerOf(testTokenId), address(to));
        assertEq(cns.balanceOf(to), 1);
        assertEq(cns.balanceOf(from), 0);
    }

    function testRenewName() public {
        vm.startPrank(FROM_ADDRESS);
        uint256 namePrice = cns.priceName(NAME);
        cns.registerName{value: namePrice}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        uint256 expiry = cns.expiry(tokenId);

        assertEq(expiry, block.timestamp + 365 days);
        uint256 namePriceNew = cns.priceName(NAME);

        cns.renewName{value: namePriceNew}(tokenId, 1);
        vm.stopPrank();
        uint256 newExpiry = cns.expiry(tokenId);

        assertEq(newExpiry, block.timestamp + 730 days);
        assertEq(cns.ownerOf(testTokenId), FROM_ADDRESS);
    }

    function testRenewNameExpired() public {
        vm.startPrank(FROM_ADDRESS);
        uint256 namePrice = cns.priceName(NAME);
        cns.registerName{value: namePrice}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);
        uint256 expiry = cns.expiry(tokenId);

        assertEq(expiry, block.timestamp + 365 days);
        uint256 namePriceNew = cns.priceName(NAME);

        vm.warp(block.timestamp + 367 days);

        cns.renewName{value: namePriceNew}(tokenId, 1);
        vm.stopPrank();

        uint256 newExpiry = cns.expiry(tokenId);

        assertEq(newExpiry, block.timestamp + 365 days);
        assertEq(cns.ownerOf(testTokenId), FROM_ADDRESS);
    }

    function testAllowNonOwnerToRenewName() public {
        vm.prank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        vm.startPrank(DEAD);

        uint256 newPrice = cns.priceName(NAME);
        cns.renewName{value: newPrice}(tokenId, 1);
        vm.stopPrank();
    }

    function testInvalidTermRenewName() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        vm.expectRevert(CantoNameService.InvalidTerm.selector);
        cns.renewName{value: price}(tokenId, 0);
        vm.stopPrank();
    }

    function testInvalidPaymentRenewName() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 tokenId = cns.nameToId(NAME);

        vm.expectRevert(CantoNameService.InvalidPayment.selector);
        cns.renewName{value: 1 wei}(tokenId, 1);
        vm.stopPrank();
    }

    function testRegisterAllowlist() public {
        address from = address(0x2eB5e5713A874786af6Da95f6E4DEaCEdb5dC246);
        address to = address(0x50664edE715e131F584D3E7EaAbd7818Bb20A068);

        vm.prank(FROM_ADDRESS);
        cns.registerNameOnAllowlist{value: price}(NAME, SIGNATURE);
        cns.transferFrom(from, to, testTokenId);

        assertEq(cns.ownerOf(testTokenId), address(to));
        assertEq(cns.balanceOf(to), 1);
        assertEq(cns.balanceOf(from), 0);
    }

    function testRevertAlreadyClaimedRegisterAllowlist() public {
        vm.prank(FROM_ADDRESS);
        cns.registerNameOnAllowlist{value: (price / 2)}(NAME, SIGNATURE);
        vm.expectRevert();
        cns.registerNameOnAllowlist{value: (price / 2)}(NAME, SIGNATURE);
    }

    function testRevertInvalidSignatureRegisterAllowlist() public {
        vm.prank(FROM_ADDRESS);
        vm.expectRevert();
        cns.registerNameOnAllowlist{value: (price / 2) * 1 wei}(NAME, "0xcat");
    }

    function testRevertHasWhitespaceRegisterAllowlist() public {
        vm.prank(FROM_ADDRESS);
        vm.expectRevert();
        cns.registerNameOnAllowlist{value: (price / 2) * 1 wei}(" cat ", "0xcat");
    }

    function testRevertInvalidPaymentRegisterAllowlist() public {
        vm.prank(FROM_ADDRESS);
        vm.expectRevert();
        cns.registerNameOnAllowlist{value: 1 wei}(NAME, SIGNATURE);
    }

    function testRevertStringLengthZeroRegisterAllowlist() public {
        vm.prank(FROM_ADDRESS);
        vm.expectRevert();
        cns.registerNameOnAllowlist{value: price}("", "0xcat");
    }

    function testRevertInvalidStatusRegisterAllowlist() public {
        vm.startPrank(OWNER_ADDRESS);
        cns.setStatus(0);
        vm.expectRevert();
        cns.registerNameOnAllowlist{value: price}(NAME, SIGNATURE);
        vm.stopPrank();
    }

    function testTotalSupply() public {
        address from = address(0xABCD);

        vm.deal(from, 100000e18);
        assertEq(cns.totalSupply(), 0);
        bytes memory sigOne = signMessageWithPK(from, "t");
        bytes memory sigTwo = signMessageWithPK(from, "te");
        bytes memory sigThree = signMessageWithPK(from, "tes");
        bytes memory sigFour = signMessageWithPK(from, "test");
        bytes memory sigFive = signMessageWithPK(from, "tests");
        bytes memory sigSix = signMessageWithPK(from, "testss");
        bytes memory sigSeven = signMessageWithPK(from, "testsss");
        bytes memory sigEight = signMessageWithPK(from, "testssss");

        vm.startPrank(from);
        cns.registerName{value: cns.priceName("t") * 1 wei}("t", 1, sigOne);
        assertEq(cns.totalSupply(), 1);
        cns.registerName{value: cns.priceName("te") * 1 wei}("te", 1, sigTwo);
        assertEq(cns.totalSupply(), 2);
        cns.registerName{value: cns.priceName("tes") * 1 wei}("tes", 1, sigThree);
        assertEq(cns.totalSupply(), 3);
        cns.registerName{value: cns.priceName("test") * 1 wei}("test", 1, sigFour);
        assertEq(cns.totalSupply(), 4);
        cns.registerName{value: cns.priceName("tests") * 1 wei}("tests", 1, sigFive);
        assertEq(cns.totalSupply(), 5);
        cns.registerName{value: cns.priceName("testss") * 1 wei}("testss", 1, sigSix);
        assertEq(cns.totalSupply(), 6);
        cns.registerName{value: cns.priceName("testsss") * 1 wei}("testsss", 1, sigSeven);
        assertEq(cns.totalSupply(), 7);
        cns.registerName{value: cns.priceName("testssss") * 1 wei}("testssss", 1, sigEight);
        assertEq(cns.totalSupply(), 8);
        vm.stopPrank();
    }

    function testTokenCounts() public {
        address from = address(0xABCD);
        bytes memory sigOne = signMessageWithPK(from, "t");
        bytes memory sigTwo = signMessageWithPK(from, "te");
        bytes memory sigThree = signMessageWithPK(from, "tes");
        bytes memory sigFour = signMessageWithPK(from, "test");
        bytes memory sigFive = signMessageWithPK(from, "tests");
        bytes memory sigSix = signMessageWithPK(from, "testss");
        bytes memory sigSeven = signMessageWithPK(from, "testsss");
        bytes memory sigEight = signMessageWithPK(from, "testssss");

        vm.deal(from, 100000e18);
        assertEq(cns.tokenCounts(0), 0);
        assertEq(cns.tokenCounts(1), 0);
        assertEq(cns.tokenCounts(2), 0);
        assertEq(cns.tokenCounts(3), 0);
        assertEq(cns.tokenCounts(4), 0);
        assertEq(cns.tokenCounts(5), 0);
        assertEq(cns.tokenCounts(6), 0);
        vm.startPrank(from);

        cns.registerName{value: cns.priceName("t") * 1 wei}("t", 1, sigOne);
        assertEq(cns.tokenCounts(1), 1);
        cns.registerName{value: cns.priceName("te") * 1 wei}("te", 1, sigTwo);
        assertEq(cns.tokenCounts(2), 1);
        cns.registerName{value: cns.priceName("tes") * 1 wei}("tes", 1, sigThree);
        assertEq(cns.tokenCounts(3), 1);
        cns.registerName{value: cns.priceName("test") * 1 wei}("test", 1, sigFour);
        assertEq(cns.tokenCounts(4), 1);
        cns.registerName{value: cns.priceName("tests") * 1 wei}("tests", 1, sigFive);
        assertEq(cns.tokenCounts(5), 1);
        cns.registerName{value: cns.priceName("testss") * 1 wei}("testss", 1, sigSix);
        assertEq(cns.tokenCounts(6), 1);
        cns.registerName{value: cns.priceName("testsss") * 1 wei}("testsss", 1, sigSeven);
        assertEq(cns.tokenCounts(6), 2);
        cns.registerName{value: cns.priceName("testssss") * 1 wei}("testssss", 1, sigEight);
        assertEq(cns.tokenCounts(6), 3);
        assertEq(cns.tokenCounts(0), 0);
        vm.stopPrank();
    }

    function testSafeTransferFromToEOA() public {
        address to = address(0xBEEF);

        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);

        cns.setApprovalForAll(address(this), true);

        cns.safeTransferFrom(FROM_ADDRESS, to, testTokenId);
        vm.stopPrank();

        assertEq(cns.getApproved(testTokenId), address(0));
        assertEq(cns.ownerOf(testTokenId), to);
        assertEq(cns.balanceOf(to), 1);
        assertEq(cns.balanceOf(FROM_ADDRESS), 0);
    }

    function testSafeTransferFromToERC721Recipient() public {
        ERC721Recipient recipient = new ERC721Recipient();
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        cns.setApprovalForAll(address(recipient), true);

        cns.safeTransferFrom(FROM_ADDRESS, address(recipient), testTokenId);
        vm.stopPrank();

        assertEq(cns.getApproved(testTokenId), address(0));
        assertEq(cns.ownerOf(testTokenId), address(recipient));
        assertEq(cns.balanceOf(address(recipient)), 1);
        assertEq(cns.balanceOf(FROM_ADDRESS), 0);
    }

    function testRevertRegisterToZero() public {
        vm.startPrank(address(0));
        vm.expectRevert();
        cns.registerName{value: price}("test", 1, SIGNATURE);
        vm.stopPrank();
    }

    function testRevertDoubleRegister() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        vm.expectRevert();
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        vm.stopPrank();
    }

    function testRevertTransferFromUnowned() public {
        vm.expectRevert();
        cns.transferFrom(address(0xBEEF), address(0xCAFE), testTokenId);
    }

    function testRevertTransferFromNotOwner() public {
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        vm.expectRevert();
        cns.transferFrom(address(0xFEED), address(0xBEEF), testTokenId);
        vm.stopPrank();
    }

    function testRevertSafeTransferFromToNonERC721Recipient() public {
        address to = address(new NonERC721Recipient());
        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);

        vm.expectRevert();
        cns.safeTransferFrom(FROM_ADDRESS, to, testTokenId);
        vm.stopPrank();
    }

    function testRevertSafeRegisterToNonERC721Recipient() public {
        address to = address(new NonERC721Recipient());
        bytes memory signature = signMessageWithPK(to, NAME);

        vm.startPrank(to);
        vm.expectRevert();
        cns.registerName{value: price}(NAME, 1, signature);
        vm.stopPrank();
    }

    function testOwnerOfUnregisteredIsBurnAddress() public {
        vm.expectRevert();
        address owner = cns.ownerOf(666);
        assertEq(owner, address(0));
    }

    function testTransferChangePrimary() public {
        address to = address(0xCAFE);

        vm.startPrank(FROM_ADDRESS);
        cns.registerName{value: price}(NAME, 1, SIGNATURE);
        uint256 primaryTokenId = cns.nameToId("test");
        cns.setPrimaryName(primaryTokenId, address(0x0));

        string memory primary = cns.getPrimary(FROM_ADDRESS);

        assertEq(primary, "test");

        cns.transferFrom(FROM_ADDRESS, to, primaryTokenId);

        vm.expectRevert(CantoNameService.NoPrimaryName.selector);
        cns.getPrimary(FROM_ADDRESS);

        vm.stopPrank();
    }

    // Removed length check to save gas, relied on backend api to check length and pass valid signature

    function testMultibyteCharactersLength() public {
        string memory _string = unicode"😃😃😃";
        uint256 length = _stringLength(_string);
        assertEq(length, 3);

        string memory _stringThree = unicode"€";
        uint256 lengthThree = _stringLength(_stringThree);
        assertEq(lengthThree, 1);
    }

    function testAltCharStringLength() public {
        string memory _string = unicode"�]";

        uint256 length = _stringLength(_string);
        assertEq(length, 2);
    }

    function testAlphanumericStringLengthOne() public {
        string memory _string = "a";

        uint256 length = _stringLength(_string);
        assertEq(length, 1);
    }

    function testAlphanumericStringLengthTwo() public {
        string memory _string = "ab";

        uint256 length = _stringLength(_string);
        assertEq(length, 2);
    }

    function testAlphanumericStringLengthThree() public {
        string memory _string = "abc";

        uint256 length = _stringLength(_string);
        assertEq(length, 3);
    }

    function testAlphanumericStringLengthFour() public {
        string memory _string = "abcd";

        uint256 length = _stringLength(_string);
        assertEq(length, 4);
    }

    function testAlphanumericStringLengthFive() public {
        string memory _string = "abcde";

        uint256 length = _stringLength(_string);
        assertEq(length, 5);
    }

    function testAlphanumericStringLengthSix() public {
        string memory _string = "abcdef";

        uint256 length = _stringLength(_string);
        assertEq(length, 6);
    }

    function testAlphanumericStringLengthSeven() public {
        string memory _string = "abcdefg";

        uint256 length = _stringLength(_string);
        assertEq(length, 6);
    }

    function testAlphanumericStringLengthZero() public {
        string memory _string = "";

        uint256 length = _stringLength(_string);
        assertEq(length, 0);
    }

    function hasWhiteSpace(string memory str) public pure returns (bool) {
        bytes memory bstr = bytes(str);
        for (uint256 i; i < bstr.length; i++) {
            if (bstr[i] == " ") {
                return true;
            }
        }
        return false;
    }

    string _stringToTest = unicode"😃€";
    uint256 expectedLength = 2;

    function testUnicodeLength() public {
        uint256 length = _stringLength(_stringToTest);
        assertEq(length, expectedLength);
    }

    function testWhiteSpace() public {
        string memory _string = unicode" a ";

        assertEq(true, this.hasWhiteSpace(_string));
    }

    function testNoWhiteSpace() public {
        string memory _string = "asdfasdfasdfsadfasdfasdfasdfasdfasdfa";

        assertEq(false, this.hasWhiteSpace(_string));
    }

    function testFuzz_Register(string memory _name) public {
        vm.assume(_stringLength(_name) > 0);
        vm.assume(!hasWhiteSpace(_name));
        address _to = address(0xBEEF);
        vm.deal(_to, 100000e18);
        uint256 _price = cns.priceName(_name);

        bytes memory signature = signMessageWithPK(_to, _name);

        vm.prank(_to);
        cns.registerName{value: _price}(_name, 1, signature);

        assertEq(cns.balanceOf(_to), 1);

        uint256 _tokenId = cns.nameToId(_name);
        assertEq(cns.ownerOf(_tokenId), _to);
    }

    function testFuzz_SetupSingleVRGDAEvent(uint256 _length) public {
        int256 tempTargetPrice = 200e18;
        int256 tempPriceDecay = 0.4e18;
        int256 tempBasePerTimeUnit = 2e18;

        _length = bound(_length, 1, 10000);

        vm.startPrank(OWNER_ADDRESS);
        vm.expectEmit(true, true, true, true);

        emit SetupVRGDA(_length, tempTargetPrice, tempPriceDecay, tempBasePerTimeUnit);

        cns.setupSingleVRGDA(_length, tempTargetPrice, tempPriceDecay, tempBasePerTimeUnit);
        vm.stopPrank();
    }

    function testFuzz_RefundOverpay(uint256 _overpay) public {
        vm.deal(FROM_ADDRESS, 100000e18);
        vm.prank(FROM_ADDRESS);

        _overpay = bound(_overpay, 0, 10000e18);

        uint256 registrantBalance = address(FROM_ADDRESS).balance;

        cns.registerName{value: price + _overpay}(NAME, 1, SIGNATURE);

        assertEq(registrantBalance - price, address(FROM_ADDRESS).balance);
    }

    function testFuzz_Register(string memory _name, uint256 _term) public {
        vm.assume(_stringLength(_name) > 0);
        vm.assume(!hasWhiteSpace(_name));
        vm.assume(_term < 2000);
        vm.assume(_term > 0);
        address _to = address(0xBEEF);
        vm.deal(_to, 100000000000e18);
        uint256 _price = cns.priceName(_name);

        bytes memory signature = signMessageWithPK(_to, _name);

        vm.prank(_to);
        cns.registerName{value: _price * _term}(_name, _term, signature);

        assertEq(cns.balanceOf(_to), 1);

        uint256 _tokenId = cns.nameToId(_name);
        assertEq(cns.ownerOf(_tokenId), _to);
    }

    function testFuzzTransferOwnership(address newOwner) public {
        vm.startPrank(OWNER_ADDRESS);
        cns.transferOwnership(newOwner);
        vm.stopPrank();

        assertEq(cns.owner(), newOwner);
    }

    function _stringLength(string memory _string) internal pure returns (uint256 result) {
        assembly {
            if mload(_string) {
                mstore(0x00, div(not(0), 255))
                mstore(0x20, 0x0202020202020202020202020202020202020202020202020303030304040506)
                let o := add(_string, 0x20)
                let end := add(o, mload(_string))

                for { result := 1 } lt(result, 6) { result := add(result, 1) } {
                    o := add(o, byte(0, mload(shr(250, mload(o)))))
                    if iszero(lt(o, end)) { break }
                }
            }
        }
        return result;
    }

    function recover(bytes32 hash, bytes calldata signature) external view returns (address) {
        return ECDSA.recover(hash, signature);
    }

    function recover(bytes32 hash, bytes32 r, bytes32 vs) external view returns (address) {
        return ECDSA.recover(hash, r, vs);
    }

    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) external view returns (address) {
        return ECDSA.recover(hash, v, r, s);
    }
    // https://github.com/transmissions11/solmate/blob/main/src/test/utils/DSTestPlus.sol

    function assertRelApproxEq(
        uint256 a,
        uint256 b,
        uint256 maxPercentDelta // An 18 decimal fixed point number, where 1e18 == 100%
    ) internal virtual {
        if (b == 0) return assertEq(a, b); // If the expected is 0, actual must be too.

        uint256 percentDelta = ((a > b ? a - b : b - a) * 1e18) / b;

        if (percentDelta > maxPercentDelta) {
            emit log("Error: a ~= b not satisfied [uint]");
            emit log_named_uint("    Expected", b);
            emit log_named_uint("      Actual", a);
            emit log_named_decimal_uint(" Max % Delta", maxPercentDelta, 18);
            emit log_named_decimal_uint("     % Delta", percentDelta, 18);
            fail();
        }
    }
}

// to be used when testing Turnstile contract. will fail unless
// turnstile.register(tx.origin) is uncommented out in CantoNameService.sol

// function testCSRTurnstile() public {
//     uint256 currentCounterId = turnstile.currentCounterId();

//     assertEq(currentCounterId, 1);

//     (uint256 registeredTokenId, bool registered) = turnstile.feeRecipient(address(cns));

//     console2.log("REGISTERED TOKEN ID", registeredTokenId);
//     console2.log("REGISTERED", registered);

//     address CSRNFTHolder = turnstile.ownerOf(registeredTokenId);
//     console2.log("CSRNFTHOLDER: ", CSRNFTHolder);

//     vm.prank(FROM_ADDRESS);
//     cns.registerName{value: price}(NAME, 1, SIGNATURE);

//     vm.prank(TURNSTILE_DEPLOYER);
//     vm.deal(TURNSTILE_DEPLOYER, 10 ether);
//     turnstile.distributeFees{value: 10 ether}(registeredTokenId);

//     vm.startPrank(OWNER_ADDRESS);
//     uint256 ownerPreBalance = address(OWNER_ADDRESS).balance;

//     uint256 tokenBalance = turnstile.balances(registeredTokenId);

//     turnstile.withdraw(registeredTokenId, payable(OWNER_ADDRESS), tokenBalance);

//     uint256 ownerPostBalance = OWNER_ADDRESS.balance;
//     vm.stopPrank();

//     assertEq(ownerPreBalance + 10 ether, ownerPostBalance);
// }

contract ERC721Recipient is ERC721TokenReceiver {
    address public operator;
    address public from;
    uint256 public id;
    bytes public data;

    function onERC721Received(address _operator, address _from, uint256 _id, bytes calldata _data)
        public
        virtual
        override
        returns (bytes4)
    {
        operator = _operator;
        from = _from;
        id = _id;
        data = _data;

        return ERC721TokenReceiver.onERC721Received.selector;
    }
}

contract MockFailWithdraw {}

contract NonERC721Recipient {}
