// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";

contract RevertingOracle is IOracle {
    uint256 internal oraclePrice = ORACLE_PRICE_SCALE;
    bool internal shouldRevert;

    function setReverts(bool newShouldRevert) external {
        shouldRevert = newShouldRevert;
    }

    function setPrice(uint256 newPrice) external {
        oraclePrice = newPrice;
    }

    function price() external view returns (uint256) {
        if (shouldRevert) revert("ORACLE_REVERT");
        return oraclePrice;
    }
}

contract LCCSetOracleTest is LCCBase {
    uint256 internal constant DEADLINE = START + NORMAL + PRE_CALL + FUNDING;
    uint256 internal constant WINDOW_END = START + EPOCH;

    function testSetMarginOracleRotatesAndEmits() public {
        OracleMock newOracle = _oracleWithPrice(2 * ORACLE_PRICE_SCALE);

        vm.expectEmit(true, true, false, true, address(vault));
        emit LCCEventsLib.MarginOracleUpdated(address(oracle), address(newOracle));
        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));

        assertEq(vault.assetConfig().marginOracle, address(newOracle));
    }

    function testSetMarginOracleRejectsZeroAddress() public {
        vm.expectRevert(LCCErrorsLib.ZeroAddress.selector);
        vm.prank(owner);
        vault.setMarginOracle(address(0));
    }

    function testSetMarginOracleRejectsDeadNewOracle() public {
        OracleMock newOracle = _oracleWithPrice(0);

        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));
    }

    function testSetMarginOracleRejectsLiveAuction() public {
        _deployAuctionVault();
        _setupShortfallAuction();
        OracleMock newOracle = _oracleWithPrice(2 * ORACLE_PRICE_SCALE);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));
    }

    function testSetMarginOracleRotatesResponsiveOracleDuringPausedLiveAuction() public {
        _deployAuctionVault();
        _setupShortfallAuction();
        OracleMock newOracle = _oracleWithPrice(2 * ORACLE_PRICE_SCALE);

        vm.warp(DEADLINE + 10);
        vm.prank(owner);
        vault.pause();
        vm.warp(DEADLINE + 1 days);

        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));
        assertEq(vault.assetConfig().marginOracle, address(newOracle));

        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vm.prank(carol);
        vault.takeAuction(25e18);

        vm.prank(owner);
        vault.unpause();
        vm.prank(carol);
        (uint256 filled, uint256 award) = vault.takeAuction(25e18);

        assertEq(filled, 25e18);
        assertEq(award, 12.5e18);
    }

    function testSetMarginOracleRotatesDuringLiveAuctionWhenOracleDead() public {
        _deployAuctionVault();
        _setupShortfallAuction();

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        oracle.setPrice(0);
        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        vm.prank(carol);
        vault.takeAuction(10e18);

        OracleMock newOracle = _oracleWithPrice(2 * ORACLE_PRICE_SCALE);
        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));

        vm.warp(DEADLINE + 10);
        vm.prank(carol);
        (uint256 filled, uint256 award) = vault.takeAuction(25e18);

        assertEq(filled, 25e18);
        assertEq(award, 12.5e18);
    }

    function testSetMarginOracleRotatesDuringLiveAuctionWhenOracleReverts() public {
        _deployAuctionVault();
        RevertingOracle revertingOracle = new RevertingOracle();
        vm.prank(owner);
        vault.setMarginOracle(address(revertingOracle));

        _setupShortfallAuction();

        revertingOracle.setReverts(true);
        OracleMock newOracle = _oracleWithPrice(2 * ORACLE_PRICE_SCALE);
        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));

        assertEq(vault.assetConfig().marginOracle, address(newOracle));
    }

    function testSetMarginOracleLiveAuctionBoundaryWithAliveOracle() public {
        _deployAuctionVault();
        _setupShortfallAuction();
        OracleMock newOracle = _oracleWithPrice(2 * ORACLE_PRICE_SCALE);

        vm.warp(WINDOW_END - 1);
        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));

        vm.warp(WINDOW_END);
        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));

        assertEq(vault.assetConfig().marginOracle, address(newOracle));
    }

    function testSetMarginOracleRecoversFromDeadOracleWithWindowClosedAuction() public {
        _deployAuctionVault();
        _setupShortfallAuction();

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        oracle.setPrice(0);
        vm.warp(WINDOW_END + 1);

        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        vault.materializeAccount(alice);

        OracleMock newOracle = _oracleWithPrice(2 * ORACLE_PRICE_SCALE);
        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));

        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertTrue(state.slashFinalized);
    }

    function testSetMarginOracleRecoversDueSlashDisposalFromDeadOldOracle() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();

        oracle.setPrice(0);
        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        vault.materializeAccount(alice);

        OracleMock newOracle = _oracleWithPrice(2 * ORACLE_PRICE_SCALE);
        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));

        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertTrue(state.slashFinalized);
        assertEq(state.slashedMargin, 100e18);
        assertEq(state.returnPool, 100e18);
        assertEq(state.returnCommitment, 400e18);
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
    }

    function testSetMarginOracleRepricesUnsettledCallAuctionAndReturnPool() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);

        OracleMock newOracle = _oracleWithPrice(10 * ORACLE_PRICE_SCALE);
        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));

        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(DEADLINE + 10);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(25e18);
        assertEq(award, 2.5e18);

        vm.warp(WINDOW_END);
        vault.materializeAccount(carol);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(state.returnPool, 47.25e18);
        assertEq(state.returnCommitment, 945e18);
        assertEq(_accruedTreasuryMargin(), 0.25e18);
    }

    function _setupShortfallAuction() internal {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);
    }

    function _oracleWithPrice(uint256 price) internal returns (OracleMock newOracle) {
        newOracle = new OracleMock();
        newOracle.setPrice(price);
    }
}
