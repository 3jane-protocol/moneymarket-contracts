// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {LCCVaultFactory} from "../../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCFactoryTest is LCCBase {
    address internal factoryOwner = makeAddr("factoryOwner");
    address internal outsider = makeAddr("outsider");

    function testFactoryCreatesAndTracksVault() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner);

        vm.prank(factoryOwner);
        address created = factory.createVault(_params(CAP, CAP));

        assertTrue(factory.isVault(created));
        assertEq(factory.numVaults(), 1);
        assertEq(factory.allVaults()[0], created);
    }

    function testFactoryTracksMultipleVaults() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner);

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
        new LCCVaultFactory(address(0));
    }

    function testFactoryRejectsNonOwnerCreateVault() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner);

        vm.expectRevert(LCCErrorsLib.NotOwner.selector);
        vm.prank(outsider);
        factory.createVault(_params(CAP, CAP));
    }

    function testFactoryOwnerCreatesAndRegistersVault() public {
        LCCVaultFactory factory = new LCCVaultFactory(factoryOwner);

        assertEq(factory.owner(), factoryOwner);

        vm.prank(factoryOwner);
        address created = factory.createVault(_params(CAP, CAP));

        assertTrue(factory.isVault(created));
        assertEq(factory.numVaults(), 1);
        assertEq(factory.allVaults()[0], created);
    }

    function testConstructorValidation() public {
        ILCCVault.VaultParams memory badAsset = _params(CAP, CAP);
        badAsset.fundingAsset = address(margin);

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        new LCCVault(badAsset);

        ILCCVault.VaultParams memory zeroTreasury = _params(CAP, CAP);
        zeroTreasury.treasury = address(0);

        vm.expectRevert(LCCErrorsLib.ZeroAddress.selector);
        new LCCVault(zeroTreasury);

        ILCCVault.VaultParams memory excessiveExitDelay = _params(CAP, CAP);
        excessiveExitDelay.exitDelayEpochs = 65;

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        new LCCVault(excessiveExitDelay);

        ILCCVault.VaultParams memory maxExitDelay = _params(CAP, CAP);
        maxExitDelay.exitDelayEpochs = 64;

        LCCVault maxDelayVault = new LCCVault(maxExitDelay);
        assertEq(maxDelayVault.epochConfig().exitDelayEpochs, 64);

        ILCCVault.VaultParams memory belowFloorExitCap = _params(CAP, CAP);
        belowFloorExitCap.exitCapBps = 312;

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        new LCCVault(belowFloorExitCap);

        ILCCVault.VaultParams memory floorExitCap = _params(CAP, CAP);
        floorExitCap.exitCapBps = 313;

        LCCVault floorVault = new LCCVault(floorExitCap);
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
