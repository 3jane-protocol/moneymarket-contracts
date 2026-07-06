// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCAssetOnlyVault, LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {LCCVaultFactory} from "../../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCFactoryTest is LCCBase {
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
        address second = factory.createVault(_params(CAP, CAP));
        vm.stopPrank();

        assertTrue(first != second);
        assertTrue(factory.isVault(first));
        assertTrue(factory.isVault(second));
        assertEq(factory.numVaults(), 2);
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

        vm.expectRevert(LCCErrorsLib.NotOwner.selector);
        vm.prank(outsider);
        factory.createVault(_params(CAP, CAP));
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
        vault.setRiskCaps(CAP, CAP, 313, 0);
        assertEq(vault.riskConfig().exitCapBps, 313);
    }
}

contract LCCZeroImplBeacon {
    function implementation() external pure returns (address) {
        return address(0);
    }
}
