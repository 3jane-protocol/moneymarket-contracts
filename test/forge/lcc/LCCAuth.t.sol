// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {BeaconProxy} from "../../../lib/openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";

contract LCCCapturedFactoryDeployer {
    function deploy(address beacon, ILCCVault.VaultParams calldata params) external returns (LCCVault) {
        return LCCVault(address(new BeaconProxy(beacon, abi.encodeCall(ILCCVault.initialize, (params)))));
    }
}

contract LCCRevertingCapturedFactory is LCCCapturedFactoryDeployer {
    fallback() external {
        revert("HOSTILE_FACTORY");
    }
}

contract LCCMalformedCapturedFactory is LCCCapturedFactoryDeployer {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(31, 1)
        }
    }
}

contract LCCLyingCapturedFactory is LCCCapturedFactoryDeployer {
    function authorizeDeposit(address, bool) external {}

    function isOwner(address) external pure returns (bool) {
        return true;
    }

    function isGuardian(address) external pure returns (bool) {
        return true;
    }

    function isBouncer(address) external pure returns (bool) {
        return true;
    }
}

contract LCCAuthTest is LCCBase {
    address internal currentOwner = makeAddr("currentOwner");

    function setUp() public override {
        super.setUp();
        factory.transferOwnership(currentOwner);
        vm.prank(currentOwner);
        factory.acceptOwnership();
    }

    function testSetRiskCapsAuthorityMatrix() public {
        bytes memory callData = abi.encodeCall(vault.setRiskCaps, (CAP, CAP, 2_000, 1));
        _assertFormerOwnerEntrypointDenied(callData);

        vm.prank(currentOwner);
        vault.setRiskCaps(CAP, CAP, 2_000, 1);
        assertEq(vault.riskConfig().minDepositAssets, 1);
    }

    function testSetMaxAuctionAwardBpsAuthorityMatrix() public {
        bytes memory callData = abi.encodeCall(vault.setMaxAuctionAwardBps, (0));
        _assertFormerOwnerEntrypointDenied(callData);

        vm.prank(currentOwner);
        vault.setMaxAuctionAwardBps(0);
    }

    function testSetSlashFeeBpsAuthorityMatrix() public {
        bytes memory callData = abi.encodeCall(vault.setSlashFeeBps, (0));
        _assertFormerOwnerEntrypointDenied(callData);

        vm.prank(currentOwner);
        vault.setSlashFeeBps(0);
    }

    function testSetMarginOracleAuthorityMatrix() public {
        OracleMock nextOracle = new OracleMock();
        nextOracle.setPrice(ORACLE_PRICE_SCALE);
        bytes memory callData = abi.encodeCall(vault.setMarginOracle, (address(nextOracle)));
        _assertFormerOwnerEntrypointDenied(callData);

        vm.prank(currentOwner);
        vault.setMarginOracle(address(nextOracle));
        assertEq(vault.assetConfig().marginOracle, address(nextOracle));
    }

    function testUnpauseAuthorityMatrix() public {
        vm.prank(guardian);
        vault.pause();
        bytes memory callData = abi.encodeCall(vault.unpause, ());
        _assertFormerOwnerEntrypointDenied(callData);

        vm.prank(currentOwner);
        vault.unpause();
        (bool paused,,) = vault.pauseState();
        assertFalse(paused);
    }

    function testShutdownAuthorityMatrix() public {
        bytes memory callData = abi.encodeCall(vault.shutdown, ());
        _assertFormerOwnerEntrypointDenied(callData);

        vm.prank(currentOwner);
        vault.shutdown();
        assertTrue(vault.shutdownState().active);
    }

    function testOpenEpochCallAuthorityMatrix() public {
        _deposit(alice, 100e18);
        vm.warp(START + NORMAL);
        bytes memory callData = abi.encodeCall(vault.openEpochCall, (0, 100e18));
        _assertFormerOwnerEntrypointDenied(callData);

        vm.prank(currentOwner);
        vault.openEpochCall(0, 100e18);
        assertTrue(vault.getEpochState(0).callOpened);
    }

    function testMockFactoryScaffoldUsesCapturedAuthority() public {
        LCCVault mockFactoryVault = _newVaultWithMockFactory(_params(CAP, CAP));

        vm.expectRevert(LCCErrorsLib.Unauthorized.selector);
        vm.prank(stranger);
        mockFactoryVault.setRiskCaps(CAP, CAP, 2_000, 1);

        vm.prank(owner);
        mockFactoryVault.setRiskCaps(CAP, CAP, 2_000, 1);
        assertEq(mockFactoryVault.riskConfig().minDepositAssets, 1);
    }

    function testCapturedLyingFactoryDefinesAllVaultAuthorityAndAdmission() public {
        LCCLyingCapturedFactory lyingFactory = new LCCLyingCapturedFactory();
        LCCVault target = lyingFactory.deploy(address(beacon), _params(CAP, CAP));

        vm.prank(stranger);
        target.setRiskCaps(CAP, CAP, 2_000, 0);
        vm.prank(stranger);
        target.pause();
        vm.prank(stranger);
        target.unpause();

        _mintAndApprove(target, alice, 10e18, 0);
        vm.prank(alice);
        uint256 commitment = target.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        vm.prank(stranger);
        assertEq(target.bounceCommitment(alice, commitment), 10e18);
    }

    function testCapturedRevertingFactoryMakesAuthorityAndAdmissionFailClosed() public {
        LCCRevertingCapturedFactory revertingFactory = new LCCRevertingCapturedFactory();
        LCCVault target = revertingFactory.deploy(address(beacon), _params(CAP, CAP));

        vm.expectRevert("HOSTILE_FACTORY");
        target.setRiskCaps(CAP, CAP, 2_000, 0);

        _mintAndApprove(target, alice, 10e18, 0);
        vm.expectRevert("HOSTILE_FACTORY");
        vm.prank(alice);
        target.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(target.getAccount(alice).activeMargin, 0);
    }

    function testCapturedMalformedFactoryReturnMakesBooleanAuthorityFailClosed() public {
        LCCMalformedCapturedFactory malformedFactory = new LCCMalformedCapturedFactory();
        LCCVault target = malformedFactory.deploy(address(beacon), _params(CAP, CAP));

        vm.expectRevert();
        target.setRiskCaps(CAP, CAP, 2_000, 0);

        _mintAndApprove(target, alice, 10e18, 0);
        vm.prank(alice);
        uint256 commitment = target.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);

        vm.expectRevert();
        target.bounceCommitment(alice, commitment);
    }

    function _assertFormerOwnerEntrypointDenied(bytes memory callData) internal {
        address[5] memory denied = [owner, lister, bouncer, guardian, stranger];
        for (uint256 i = 0; i < denied.length; ++i) {
            vm.prank(denied[i]);
            (bool ok, bytes memory result) = address(vault).call(callData);
            assertFalse(ok, "unauthorized role unexpectedly succeeded");
            assertEq(bytes4(result), LCCErrorsLib.Unauthorized.selector);
        }
    }
}
