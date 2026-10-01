// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {IIrm} from "../../../src/interfaces/IIrm.sol";
import {IMorpho, IMorphoCredit, Id, Market, MarketParams} from "../../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {MathLib, WAD} from "../../../src/libraries/MathLib.sol";
import {MorphoBalancesLib} from "../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoCreditBalancesLib} from "../../../src/libraries/periphery/MorphoCreditBalancesLib.sol";
import {MorphoCreditStorageLib} from "../../../src/libraries/periphery/MorphoCreditStorageLib.sol";
import {MorphoStorageLib} from "../../../src/libraries/periphery/MorphoStorageLib.sol";

contract AaveRebateDebtExposureTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using MorphoCreditBalancesLib for IMorphoCredit;

    address internal constant BORROWER = address(0xB0B);

    Id internal marketId;
    MockCreditMorpho internal morpho;
    MockIrm internal irm;

    function setUp() public {
        irm = new MockIrm((5 * WAD) / 100 / 365 days);
        morpho = new MockCreditMorpho();

        MarketParams memory params = MarketParams({
            loanToken: address(0),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(irm),
            lltv: 0,
            creditLine: address(0)
        });
        marketId = params.id();
        morpho.setMarketParams(params);
        morpho.setMarket(
            Market({
                totalSupplyAssets: 1_000e18,
                totalSupplyShares: 1_000e18,
                totalBorrowAssets: 1_000e18,
                totalBorrowShares: 1_000e18,
                lastUpdate: 1 days,
                fee: 0,
                totalMarkdownAmount: 0
            })
        );
        morpho.setBorrowShares(marketId, BORROWER, 1_000e18);
    }

    function test_expectedDebtExposureIncludesPendingBaseInterestAndPremium() public {
        vm.warp(31 days);

        uint128 premiumRate = uint128((25 * WAD) / 1_000 / 365 days);
        morpho.setPremium(marketId, BORROWER, uint128(1 days), premiumRate, 1_000e18);

        uint256 storedDebt = 1_000e18;
        uint256 baseExpectedDebt = IMorpho(address(morpho)).expectedBorrowAssets(morpho.marketParams(), BORROWER);
        uint256 premiumExpectedDebt = IMorphoCredit(address(morpho)).expectedBorrowAssetsWithPremium(marketId, BORROWER);

        assertGt(baseExpectedDebt, storedDebt);
        assertGt(premiumExpectedDebt, baseExpectedDebt);
    }

    function test_expectedDebtExposureReturnsZeroWhenBorrowSharesAreZero() public {
        vm.warp(31 days);

        morpho.setBorrowShares(marketId, BORROWER, 0);
        morpho.setPremium(marketId, BORROWER, uint128(1 days), uint128((25 * WAD) / 1_000 / 365 days), 1_000e18);

        uint256 premiumExpectedDebt = IMorphoCredit(address(morpho)).expectedBorrowAssetsWithPremium(marketId, BORROWER);

        assertEq(premiumExpectedDebt, 0);
    }
}

contract MockCreditMorpho {
    MarketParams internal _marketParams;
    Market internal _market;
    mapping(address => uint256) internal _borrowShares;
    mapping(bytes32 => bytes32) internal _slotData;

    function setMarketParams(MarketParams memory newMarketParams) external {
        _marketParams = newMarketParams;
    }

    function setMarket(Market memory newMarket) external {
        _market = newMarket;
    }

    function setBorrowShares(Id id, address borrower, uint256 shares) external {
        _borrowShares[borrower] = shares;
        _slotData[MorphoStorageLib.positionBorrowSharesAndCollateralSlot(id, borrower)] = bytes32(shares);
    }

    function setPremium(
        Id id,
        address borrower,
        uint128 lastAccrualTime,
        uint128 rate,
        uint128 borrowAssetsAtLastAccrual
    ) external {
        bytes32 premiumSlot = MorphoCreditStorageLib.borrowerPremiumSlot(id, borrower);
        _slotData[premiumSlot] = bytes32(uint256(lastAccrualTime) | (uint256(rate) << 128));
        _slotData[bytes32(uint256(premiumSlot) + 1)] = bytes32(uint256(borrowAssetsAtLastAccrual));
    }

    function marketParams() external view returns (MarketParams memory) {
        return _marketParams;
    }

    function idToMarketParams(Id) external view returns (MarketParams memory) {
        return _marketParams;
    }

    function market(Id) external view returns (Market memory) {
        return _market;
    }

    function borrowShares(Id, address borrower) external view returns (uint256) {
        return _borrowShares[borrower];
    }

    function extSloads(bytes32[] memory slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            values[i] = _slotData[slots[i]];
        }
    }
}

contract MockIrm is IIrm {
    uint256 internal immutable RATE;

    constructor(uint256 rate) {
        RATE = rate;
    }

    function borrowRate(MarketParams memory, Market memory) external view returns (uint256) {
        return RATE;
    }

    function borrowRateView(MarketParams memory, Market memory) external view returns (uint256) {
        return RATE;
    }
}
