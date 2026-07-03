// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {LCCVaultFactory} from "../../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCFactoryTest is LCCBase {
    function testFactoryCreatesAndTracksVault() public {
        LCCVaultFactory factory = new LCCVaultFactory();

        address created = factory.createVault(_params(CAP, CAP));

        assertTrue(factory.isVault(created));
        assertEq(factory.numVaults(), 1);
        assertEq(factory.allVaults()[0], created);
    }

    function testFactoryTracksMultipleVaults() public {
        LCCVaultFactory factory = new LCCVaultFactory();

        address first = factory.createVault(_params(CAP, CAP));
        address second = factory.createVault(_params(CAP, CAP));

        assertTrue(first != second);
        assertTrue(factory.isVault(first));
        assertTrue(factory.isVault(second));
        assertEq(factory.numVaults(), 2);
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
    }
}
