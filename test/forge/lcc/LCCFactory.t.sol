// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCAssetOnlyVault, LCCBase} from "./LCCBase.t.sol";
import {IAccessControl} from "../../../lib/openzeppelin/contracts/access/IAccessControl.sol";
import {UpgradeableBeacon} from "../../../lib/openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {LCCVaultFactory} from "../../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCFactoryTest is LCCBase {
    string internal constant AUCTION_LIB_FQN = "src/lcc/libraries/LCCAuctionLib.sol:LCCAuctionLib";
    string internal constant CONFIG_LIB_FQN = "src/lcc/libraries/LCCConfigLib.sol:LCCConfigLib";
    string internal constant EXIT_LIB_FQN = "src/lcc/libraries/LCCExitLib.sol:LCCExitLib";

    event VaultCreated(address indexed vault);

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
        vm.expectEmit(true, false, false, true, address(factory));
        emit VaultCreated(expectedPlain);
        vm.prank(factoryOwner);
        address plain = factory.createVault(params);

        address expectedCreate2 = factory.predictVaultAddress(params, salt);
        vm.expectEmit(true, false, false, true, address(factory));
        emit VaultCreated(expectedCreate2);
        vm.prank(factoryOwner);
        address deterministic = factory.createVault(params, salt);

        assertEq(plain, expectedPlain);
        assertEq(deterministic, expectedCreate2);
        assertTrue(factory.isVault(plain));
        assertTrue(factory.isVault(deterministic));
        assertEq(factory.numVaults(), 2);
        assertEq(factory.allVaults()[0], plain);
        assertEq(factory.allVaults()[1], deterministic);
        assertTrue(factory.isOwner(factoryOwner));
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
        bytes32 ownerRole = factory.OWNER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, ownerRole)
        );
        vm.prank(outsider);
        factory.createVault(params);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, ownerRole)
        );
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

    function testImplementationDeploymentDoesNotAuthenticateCodelessExitLibraryLink() public {
        address codelessExitLibrary = makeAddr("codelessExitLibrary");
        assertEq(codelessExitLibrary.code.length, 0);

        // Deliberate accepted residual: deployment authenticates every linked bytecode; see docs/deployment.md.
        address implementation = _deployImplementationWithExitLibrary(codelessExitLibrary);
        assertNotEq(implementation, address(0), "deployment procedure must authenticate linked bytecode");
    }

    function testExitLibraryRejectsZeroWordReturnForVoidCall() public {
        LCCVault mislinkedVault = _deployVaultWithExitLibrary(address(new LCCZeroWordExitLibrary()));
        _depositInto(mislinkedVault, alice, 100e18);

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        vm.prank(alice);
        mislinkedVault.requestExit(type(uint256).max, type(uint256).max);
    }

    function testExitLibraryRejectsTwoWordReturnForResultCall() public {
        LCCVault mislinkedVault = _deployVaultWithExitLibrary(address(new LCCTwoWordExitLibrary()));
        _depositInto(mislinkedVault, alice, 100e18);

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        vm.prank(alice);
        mislinkedVault.requestExit(type(uint256).max, type(uint256).max);
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

    function _deployImplementationWithExitLibrary(address exitLibrary) internal returns (address implementation) {
        string memory outDir = vm.envOr("FOUNDRY_OUT", string("out"));
        address auctionLibrary = vm.deployCode(string.concat(outDir, "/LCCAuctionLib.sol/LCCAuctionLib.json"));
        address configLibrary = vm.deployCode(string.concat(outDir, "/LCCConfigLib.sol/LCCConfigLib.json"));
        string memory hexCode =
            vm.parseJsonString(vm.readFile(string.concat(outDir, "/LCCVault.sol/LCCVault.json")), ".bytecode.object");
        hexCode = _linkLibrary(hexCode, AUCTION_LIB_FQN, auctionLibrary);
        hexCode = _linkLibrary(hexCode, CONFIG_LIB_FQN, configLibrary);
        hexCode = _linkLibrary(hexCode, EXIT_LIB_FQN, exitLibrary);
        require(!vm.contains(hexCode, "__$"), "unlinked references remain");

        bytes memory initCode =
            abi.encodePacked(vm.parseBytes(hexCode), abi.encode(address(notificationVault), treasury));
        assembly ("memory-safe") {
            implementation := create(0, add(initCode, 0x20), mload(initCode))
        }
    }

    function _deployVaultWithExitLibrary(address exitLibrary) internal returns (LCCVault mislinkedVault) {
        address implementation = _deployImplementationWithExitLibrary(exitLibrary);
        assertNotEq(implementation, address(0), "mislinked implementation deployment failed");

        UpgradeableBeacon mislinkedBeacon = new UpgradeableBeacon(implementation, owner);
        LCCVaultFactory mislinkedFactory = new LCCVaultFactory(owner, address(mislinkedBeacon));
        mislinkedFactory.grantRole(mislinkedFactory.LISTER_ROLE(), owner);
        address[] memory depositor = new address[](1);
        depositor[0] = alice;
        mislinkedFactory.setDepositorsWhitelisted(depositor, true);
        mislinkedVault = LCCVault(mislinkedFactory.createVault(_params(CAP, CAP)));
    }

    function _depositInto(LCCVault target, address depositor, uint256 assets) internal {
        margin.mint(depositor, assets);
        vm.startPrank(depositor);
        margin.approve(address(target), assets);
        target.deposit(assets, depositor, 1, type(uint256).max, true, type(uint256).max);
        vm.stopPrank();
    }

    function _linkLibrary(string memory hexCode, string memory fqn, address libraryAddress)
        internal
        returns (string memory)
    {
        string memory placeholder = string.concat("__$", _hexN(keccak256(bytes(fqn)), 17), "$__");
        require(vm.contains(hexCode, placeholder), "library link placeholder not found");
        return vm.replace(hexCode, placeholder, vm.replace(vm.toLowercase(vm.toString(libraryAddress)), "0x", ""));
    }

    function _hexN(bytes32 value, uint256 bytesLength) internal pure returns (string memory) {
        bytes memory table = "0123456789abcdef";
        bytes memory output = new bytes(2 * bytesLength);
        for (uint256 i = 0; i < bytesLength; ++i) {
            output[2 * i] = table[uint8(value[i]) >> 4];
            output[2 * i + 1] = table[uint8(value[i]) & 0x0f];
        }
        return string(output);
    }
}

contract LCCZeroImplBeacon {
    function implementation() external pure returns (address) {
        return address(0);
    }
}

contract LCCZeroWordExitLibrary {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 0x20)
        }
    }
}

contract LCCTwoWordExitLibrary {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0)
            mstore(0x20, 0)
            return(0, 0x40)
        }
    }
}
