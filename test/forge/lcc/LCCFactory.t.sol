// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCAssetOnlyVault, LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {LCCVaultFactory} from "../../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCFactoryTest is LCCBase {
    event VaultCreated(address indexed vault, address indexed owner);

    address internal factoryOwner = makeAddr("factoryOwner");
    address internal outsider = makeAddr("outsider");

    function testFactoryCreatesAndTracksVault() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner, address(beacon));

        vm.prank(factoryOwner);
        address created = factory.createVault(_params(CAP, CAP));

        assertTrue(factory.isVault(created));
        assertEq(factory.numVaults(), 1);
        assertEq(factory.allVaults()[0], created);
    }

    function testFactoryTracksMultipleVaults() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner, address(beacon));

        vm.startPrank(factoryOwner);
        address first = factory.createVault(_params(CAP, CAP));
        address second = factory.createVault(_params(CAP, CAP), keccak256("facility-b"));
        vm.stopPrank();

        assertTrue(first != second);
        assertTrue(factory.isVault(first));
        assertTrue(factory.isVault(second));
        assertEq(factory.numVaults(), 2);
    }

    function testFactoryDefaultSaltCollisionForcesExplicitSalt() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner, address(beacon));
        ILCCVault.VaultParams memory params = _params(CAP, CAP);

        vm.prank(factoryOwner);
        address first = factory.createVault(params);
        assertEq(first, factory.predictVaultAddress(params, bytes32(0)));

        vm.expectRevert();
        vm.prank(factoryOwner);
        factory.createVault(params);

        vm.prank(factoryOwner);
        address second = factory.createVault(params, keccak256("facility-b"));

        assertTrue(first != second);
        assertTrue(factory.isVault(first));
        assertTrue(factory.isVault(second));
        assertEq(factory.numVaults(), 2);
    }

    function testFactoryCreate2PredictionIsDeterministic() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner, address(beacon));
        LCCVaultFactory freshFactory = new LCCVaultFactory(factoryOwner, address(beacon));
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        bytes32 salt = keccak256("facility-a");

        address predicted = factory.predictVaultAddress(params, salt);
        address freshPredicted = freshFactory.predictVaultAddress(params, salt);

        vm.prank(factoryOwner);
        address created = factory.createVault(params, salt);

        vm.prank(factoryOwner);
        address freshCreated = freshFactory.createVault(params, salt);

        assertEq(created, predicted);
        assertEq(freshCreated, freshPredicted);
        assertNotEq(created, freshCreated);
    }

    function testFactoryCreate2SaltCollisionReverts() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner, address(beacon));
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        bytes32 salt = keccak256("facility-a");

        vm.prank(factoryOwner);
        factory.createVault(params, salt);

        vm.expectRevert();
        vm.prank(factoryOwner);
        factory.createVault(params, salt);
    }

    function testFactoryCreateOverloadsHaveRegistryAndEventParity() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner, address(beacon));
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        bytes32 salt = keccak256("facility-a");

        address expectedPlain = factory.predictVaultAddress(params, bytes32(0));
        vm.expectEmit(true, true, false, true, address(factory));
        emit VaultCreated(expectedPlain, params.owner);
        vm.prank(factoryOwner);
        address plain = factory.createVault(params);

        address expectedCreate2 = factory.predictVaultAddress(params, salt);
        vm.expectEmit(true, true, false, true, address(factory));
        emit VaultCreated(expectedCreate2, params.owner);
        vm.prank(factoryOwner);
        address deterministic = factory.createVault(params, salt);

        assertEq(plain, expectedPlain);
        assertEq(deterministic, expectedCreate2);
        assertTrue(factory.isVault(plain));
        assertTrue(factory.isVault(deterministic));
        assertEq(factory.numVaults(), 2);
        assertEq(factory.allVaults()[0], plain);
        assertEq(factory.allVaults()[1], deterministic);
        assertEq(LCCVault(plain).owner(), params.owner);
        assertEq(LCCVault(deterministic).owner(), params.owner);
    }

    function testFactoryCreate2DifferentSaltDifferentAddress() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner, address(beacon));
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        bytes32 firstSalt = keccak256("facility-a");
        bytes32 secondSalt = keccak256("facility-b");

        address firstPrediction = factory.predictVaultAddress(params, firstSalt);
        address secondPrediction = factory.predictVaultAddress(params, secondSalt);
        assertNotEq(firstPrediction, secondPrediction);

        vm.startPrank(factoryOwner);
        address first = factory.createVault(params, firstSalt);
        address second = factory.createVault(params, secondSalt);
        vm.stopPrank();

        assertEq(first, firstPrediction);
        assertEq(second, secondPrediction);
        assertNotEq(first, second);
    }

    function testFactoryCreate2SameSaltDifferentParamsDifferentAddress() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner, address(beacon));
        ILCCVault.VaultParams memory firstParams = _params(CAP, CAP);
        ILCCVault.VaultParams memory secondParams = _params(CAP, CAP / 2);
        bytes32 salt = keccak256("reusable-facility-salt");

        address firstPrediction = factory.predictVaultAddress(firstParams, salt);
        address secondPrediction = factory.predictVaultAddress(secondParams, salt);
        assertNotEq(firstPrediction, secondPrediction);

        vm.startPrank(factoryOwner);
        address first = factory.createVault(firstParams, salt);
        address second = factory.createVault(secondParams, salt);
        vm.stopPrank();

        assertEq(first, firstPrediction);
        assertEq(second, secondPrediction);
        assertNotEq(first, second);
        assertTrue(factory.isVault(first));
        assertTrue(factory.isVault(second));
    }

    function testFactoryRejectsZeroOwner() public {
        vm.expectRevert(LCCErrorsLib.ZeroAddress.selector);
        new LCCVaultFactory(address(0), address(beacon));
    }

    function testFactoryRejectsZeroBeacon() public {
        vm.expectRevert(LCCErrorsLib.ZeroAddress.selector);
        new LCCVaultFactory(factoryOwner, address(0));
    }

    function testFactoryRejectsNonBeaconAddresses() public {
        // EOA: the probe staticcall succeeds with empty returndata.
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        new LCCVaultFactory(factoryOwner, outsider);

        // Contract without implementation(): the probe staticcall reverts.
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        new LCCVaultFactory(factoryOwner, address(margin));

        // Beacon-shaped contract reporting no implementation.
        address zeroImplBeacon = address(new LCCZeroImplBeacon());
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        new LCCVaultFactory(factoryOwner, zeroImplBeacon);
    }

    function testFactoryRejectsNonOwnerCreateVault() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner, address(beacon));
        ILCCVault.VaultParams memory params = _params(CAP, CAP);

        vm.expectRevert(LCCErrorsLib.NotOwner.selector);
        vm.prank(outsider);
        factory.createVault(params);

        vm.expectRevert(LCCErrorsLib.NotOwner.selector);
        vm.prank(outsider);
        factory.createVault(params, keccak256("facility-a"));
    }

    function testFactoryOwnerCreatesAndRegistersVault() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner, address(beacon));

        assertEq(factory.owner(), factoryOwner);
        assertEq(factory.beacon(), address(beacon));

        vm.prank(factoryOwner);
        address created = factory.createVault(_params(CAP, CAP));

        assertTrue(factory.isVault(created));
        assertEq(factory.numVaults(), 1);
        assertEq(factory.allVaults()[0], created);
    }

    function testImplementationConstructorValidation() public {
        vm.expectRevert(LCCErrorsLib.ZeroAddress.selector);
        new LCCVault(address(0), treasury);

        vm.expectRevert(LCCErrorsLib.ZeroAddress.selector);
        new LCCVault(address(notificationVault), address(0));

        LCCAssetOnlyVault noUsd3 = new LCCAssetOnlyVault(address(0));
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        new LCCVault(address(noUsd3), treasury);

        LCCAssetOnlyVault noFundingAsset = new LCCAssetOnlyVault(address(0));
        LCCAssetOnlyVault badNotificationVault = new LCCAssetOnlyVault(address(noFundingAsset));
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        new LCCVault(address(badNotificationVault), treasury);
    }

    function testInitializerValidation() public {
        ILCCVault.VaultParams memory excessiveExitDelay = _params(CAP, CAP);
        excessiveExitDelay.exitDelayEpochs = 65;

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(excessiveExitDelay);

        ILCCVault.VaultParams memory maxExitDelay = _params(CAP, CAP);
        maxExitDelay.exitDelayEpochs = 64;

        LCCVault maxDelayVault = _newVault(maxExitDelay);
        assertEq(maxDelayVault.epochConfig().exitDelayEpochs, 64);

        ILCCVault.VaultParams memory belowFloorExitCap = _params(CAP, CAP);
        belowFloorExitCap.exitCapBps = 312;

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(belowFloorExitCap);

        ILCCVault.VaultParams memory floorExitCap = _params(CAP, CAP);
        floorExitCap.exitCapBps = 313;

        LCCVault floorVault = _newVault(floorExitCap);
        assertEq(floorVault.riskConfig().exitCapBps, 313);
    }

    function testSetRiskCapsEnforcesExitCapFloor() public {
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        vm.prank(owner);
        vault.setRiskCaps(CAP, CAP, 312, 0);

        vm.prank(owner);
        vault.setRiskCaps(31, CAP, 313, 0);
        assertEq(vault.riskConfig().exitCapBps, 313);
        assertEq(vault.riskConfig().protocolCommitmentCap, 31);
    }
}

contract LCCZeroImplBeacon {
    function implementation() external pure returns (address) {
        return address(0);
    }
}
