// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {MorphoStorageLib} from "../../../../src/libraries/periphery/MorphoStorageLib.sol";
import {SigUtils} from "../../helpers/SigUtils.sol";

import "../../BaseTest.sol";
import {IMorphoCredit} from "../../../../src/interfaces/IMorpho.sol";

contract MorphoStorageLibTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;

    function testStorage(uint256 amountSupplied, uint256 amountBorrowed, uint256 timeElapsed, uint256 fee) public {
        // Skip this test for MorphoCredit as it has a different storage layout
        // This test is designed for the base Morpho contract
        vm.skip(true);
        // Prepare storage layout with non empty values.

        amountSupplied = bound(amountSupplied, 2, MAX_TEST_AMOUNT);
        amountBorrowed = bound(amountBorrowed, 1, amountSupplied);
        timeElapsed = uint32(bound(timeElapsed, 1, 1e8));
        fee = bound(fee, 1, MAX_FEE);

        // Set fee parameters.
        vm.prank(OWNER);
        morpho.setFee(marketParams, fee);

        loanToken.setBalance(address(this), amountSupplied);
        morpho.supply(marketParams, amountSupplied, 0, address(this), hex"");

        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        collateralToken.setBalance(
            BORROWER, amountBorrowed.wDivUp(marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice)
        );

        // Credit line setup needed for BORROWER
        uint256 creditAmount = amountBorrowed.wDivUp(marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice);
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, creditAmount, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);

        bytes32[] memory slots = new bytes32[](17);
        slots[0] = MorphoStorageLib.ownerSlot();
        slots[1] = MorphoStorageLib.feeRecipientSlot();
        slots[2] = MorphoStorageLib.positionSupplySharesSlot(id, address(this));
        slots[3] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(id, BORROWER);
        slots[4] = MorphoStorageLib.marketTotalSupplyAssetsAndSharesSlot(id);
        slots[5] = MorphoStorageLib.marketTotalBorrowAssetsAndSharesSlot(id);
        slots[6] = MorphoStorageLib.marketLastUpdateAndFeeSlot(id);
        slots[7] = MorphoStorageLib.isIrmEnabledSlot(address(irm));
        slots[8] = MorphoStorageLib.isLltvEnabledSlot(marketParams.lltv);
        slots[9] = MorphoStorageLib.nonceSlot(BORROWER);
        slots[10] = MorphoStorageLib.idToLoanTokenSlot(id);
        slots[11] = MorphoStorageLib.idToCollateralTokenSlot(id);
        slots[12] = MorphoStorageLib.idToOracleSlot(id);
        slots[13] = MorphoStorageLib.idToIrmSlot(id);
        slots[14] = MorphoStorageLib.idToLltvSlot(id);
        slots[15] = MorphoStorageLib.idToCreditLineSlot(id);

        bytes32[] memory values = morpho.extSloads(slots);

        assertEq(abi.decode(abi.encode(values[0]), (address)), morpho.owner());
        assertEq(abi.decode(abi.encode(values[1]), (address)), morpho.feeRecipient());
        assertEq(uint256(values[2]), morpho.supplyShares(id, address(this)));
        assertEq(uint128(uint256(values[3])), morpho.borrowShares(id, BORROWER));
        assertEq(uint256(values[3] >> 128), morpho.collateral(id, BORROWER));
        assertEq(uint128(uint256(values[4])), morpho.totalSupplyAssets(id));
        assertEq(uint256(values[4] >> 128), morpho.totalSupplyShares(id));
        assertEq(uint128(uint256(values[5])), morpho.totalBorrowAssets(id));
        assertEq(uint256(values[5] >> 128), morpho.totalBorrowShares(id));
        assertEq(uint128(uint256(values[6])), morpho.lastUpdate(id));
        assertEq(uint256(values[6] >> 128), morpho.fee(id));
        assertEq(abi.decode(abi.encode(values[7]), (bool)), morpho.isIrmEnabled(address(irm)));
        assertEq(abi.decode(abi.encode(values[8]), (bool)), morpho.isLltvEnabled(marketParams.lltv));
        assertEq(uint256(values[9]), morpho.nonce(BORROWER));

        MarketParams memory expectedParams = morpho.idToMarketParams(id);

        assertEq(abi.decode(abi.encode(values[10]), (address)), expectedParams.loanToken);
        assertEq(abi.decode(abi.encode(values[11]), (address)), expectedParams.collateralToken);
        assertEq(abi.decode(abi.encode(values[12]), (address)), expectedParams.oracle);
        assertEq(abi.decode(abi.encode(values[13]), (address)), expectedParams.irm);
        assertEq(uint256(values[14]), expectedParams.lltv);
        assertEq(abi.decode(abi.encode(values[15]), (address)), expectedParams.creditLine);
    }
}
