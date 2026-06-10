// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LeveragedCallableCreditVault} from "../../../src/lcc/LeveragedCallableCreditVault.sol";
import {LeveragedCallableCreditVaultFactory} from "../../../src/lcc/LeveragedCallableCreditVaultFactory.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";

contract LCCFactoryTest is LCCBase {
    function testFactoryCreatesAndTracksVault() public {
        LeveragedCallableCreditVaultFactory factory = new LeveragedCallableCreditVaultFactory();

        address created = factory.createVault(_params(CAP, CAP));

        assertTrue(factory.isVault(created));
        assertEq(factory.numVaults(), 1);
        assertEq(factory.allVaults()[0], created);
    }

    function testFactoryTracksMultipleVaults() public {
        LeveragedCallableCreditVaultFactory factory = new LeveragedCallableCreditVaultFactory();

        address first = factory.createVault(_params(CAP, CAP));
        address second = factory.createVault(_params(CAP, CAP));

        assertTrue(first != second);
        assertTrue(factory.isVault(first));
        assertTrue(factory.isVault(second));
        assertEq(factory.numVaults(), 2);
    }

    function testConstructorValidation() public {
        ILeveragedCallableCreditVault.VaultParams memory badAsset = _params(CAP, CAP);
        badAsset.callableAsset = address(margin);

        vm.expectRevert(LeveragedCallableCreditVault.InvalidParams.selector);
        new LeveragedCallableCreditVault(badAsset);

        ILeveragedCallableCreditVault.VaultParams memory zeroTreasury = _params(CAP, CAP);
        zeroTreasury.treasury = address(0);

        vm.expectRevert(LeveragedCallableCreditVault.ZeroAddress.selector);
        new LeveragedCallableCreditVault(zeroTreasury);
    }
}
