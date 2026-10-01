// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";

import {ICreditLine} from "../../src/interfaces/ICreditLine.sol";
import {IMorpho, IMorphoCredit, Id, Market, Position} from "../../src/interfaces/IMorpho.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {ProtocolConfigLib} from "../../src/libraries/ProtocolConfigLib.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";

interface IERC4626Like {
    function previewRedeem(uint256 shares) external view returns (uint256);
}

/// @notice Reports a borrower's current debt, credit line, and remaining capacity.
/// @dev Run without --broadcast. The default entry point locally accrues borrower premium/market interest first.
contract ReportBorrowerCapacity is Script {
    using SharesMathLib for uint256;

    address private constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address private constant WA_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;

    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    struct Capacity {
        uint256 creditLine;
        uint256 borrowAssets;
        uint256 remainingCredit;
        uint256 marketTotalBorrowAssets;
        uint256 debtCap;
        uint256 remainingDebtCap;
        uint256 availableLiquidity;
        uint256 borrowableCapacity;
    }

    /// @notice Read BORROWER from env and report after local accrual simulation.
    function run() external {
        report(vm.envAddress("BORROWER"));
    }

    /// @notice Report a borrower after local accrual simulation.
    function report(address borrower) public {
        _report(borrower, true);
    }

    /// @notice Read BORROWER from env and report raw stored state without accrual simulation.
    function runViewOnly() external view {
        reportViewOnly(vm.envAddress("BORROWER"));
    }

    /// @notice Report raw stored state without accrual simulation.
    function reportViewOnly(address borrower) public view {
        _reportViewOnly(borrower);
    }

    function _report(address borrower, bool accrueFirst) internal {
        require(borrower != address(0), "borrower required");

        IMorphoCredit morphoCredit = IMorphoCredit(ICreditLine(CREDIT_LINE).MORPHO());
        IMorpho morpho = IMorpho(address(morphoCredit));

        console2.log("=== Borrower Capacity Report ===");
        console2.log("Borrower:", borrower);
        console2.log("MorphoCredit:", address(morphoCredit));
        console2.log("CreditLine:", CREDIT_LINE);
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("Accrued locally:", accrueFirst);
        console2.log("");

        if (accrueFirst) {
            address[] memory borrowers = new address[](1);
            borrowers[0] = borrower;
            morphoCredit.accruePremiumsForBorrowers(MARKET_ID, borrowers);
        }

        Capacity memory capacity = _capacity(morphoCredit, morpho, borrower);
        _logCapacity(capacity);
    }

    function _reportViewOnly(address borrower) internal view {
        require(borrower != address(0), "borrower required");

        IMorphoCredit morphoCredit = IMorphoCredit(ICreditLine(CREDIT_LINE).MORPHO());
        IMorpho morpho = IMorpho(address(morphoCredit));

        console2.log("=== Borrower Capacity Report ===");
        console2.log("Borrower:", borrower);
        console2.log("MorphoCredit:", address(morphoCredit));
        console2.log("CreditLine:", CREDIT_LINE);
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("Accrued locally:", false);
        console2.log("");

        Capacity memory capacity = _capacity(morphoCredit, morpho, borrower);
        _logCapacity(capacity);
    }

    function _capacity(IMorphoCredit morphoCredit, IMorpho morpho, address borrower)
        internal
        view
        returns (Capacity memory capacity)
    {
        Position memory position = morpho.position(MARKET_ID, borrower);
        Market memory market = morpho.market(MARKET_ID);
        uint256 debtCap = IProtocolConfig(morphoCredit.protocolConfig()).config(ProtocolConfigLib.DEBT_CAP);

        uint256 borrowAssets =
            uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 creditLine = uint256(position.collateral);
        uint256 remainingCredit = creditLine > borrowAssets ? creditLine - borrowAssets : 0;
        uint256 remainingDebtCap = debtCap > market.totalBorrowAssets ? debtCap - market.totalBorrowAssets : 0;
        uint256 availableLiquidity = market.totalSupplyAssets > market.totalBorrowAssets
            ? uint256(market.totalSupplyAssets) - uint256(market.totalBorrowAssets)
            : 0;
        uint256 borrowableCapacity = _min(remainingCredit, _min(availableLiquidity, remainingDebtCap));

        return Capacity({
            creditLine: creditLine,
            borrowAssets: borrowAssets,
            remainingCredit: remainingCredit,
            marketTotalBorrowAssets: market.totalBorrowAssets,
            debtCap: debtCap,
            remainingDebtCap: remainingDebtCap,
            availableLiquidity: availableLiquidity,
            borrowableCapacity: borrowableCapacity
        });
    }

    function _logCapacity(Capacity memory capacity) internal view {
        _logAmountPair("Current borrow", capacity.borrowAssets);
        console2.log("");
        _logAmountPair("Credit line", capacity.creditLine);
        console2.log("");
        _logAmountPair("Remaining credit", capacity.remainingCredit);
        console2.log("");
        _logAmountPair("Protocol debt cap", capacity.debtCap);
        console2.log("Market total borrow: %s waEthUSDC", _formatTokenAmount(capacity.marketTotalBorrowAssets, 6));
        console2.log(
            "Market total borrow preview: %s USDC", _formatTokenAmount(_preview(capacity.marketTotalBorrowAssets), 6)
        );
        _logAmountPair("Remaining debt cap", capacity.remainingDebtCap);
        console2.log("");
        _logAmountPair("Available liquidity", capacity.availableLiquidity);
        console2.log("");
        _logAmountPair("Borrowable capacity", capacity.borrowableCapacity);
    }

    function _logAmountPair(string memory label, uint256 waUsdcAmount) internal view {
        uint256 usdcAmount = _preview(waUsdcAmount);
        console2.log("%s: %s waEthUSDC", label, _formatTokenAmount(waUsdcAmount, 6));
        console2.log("%s preview: %s USDC", label, _formatTokenAmount(usdcAmount, 6));
    }

    function _preview(uint256 waUsdcAmount) internal view returns (uint256) {
        return IERC4626Like(WA_USDC).previewRedeem(waUsdcAmount);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _formatTokenAmount(uint256 amount, uint8 decimals) internal pure returns (string memory) {
        uint256 scale = 10 ** uint256(decimals);
        uint256 whole = amount / scale;
        uint256 fraction = amount % scale;
        return string.concat(_withCommas(whole), ".", _leftPadFraction(fraction, decimals));
    }

    function _leftPadFraction(uint256 value, uint8 width) internal pure returns (string memory) {
        bytes memory out = new bytes(width);
        for (uint256 i = width; i > 0; --i) {
            out[i - 1] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(out);
    }

    function _withCommas(uint256 value) internal pure returns (string memory) {
        string memory raw = vm.toString(value);
        bytes memory rawBytes = bytes(raw);
        if (rawBytes.length <= 3) return raw;

        uint256 commas = (rawBytes.length - 1) / 3;
        bytes memory out = new bytes(rawBytes.length + commas);

        uint256 rawIndex = rawBytes.length;
        uint256 outIndex = out.length;
        uint256 groupCount;

        while (rawIndex > 0) {
            if (groupCount == 3) {
                out[--outIndex] = ",";
                groupCount = 0;
            }

            out[--outIndex] = rawBytes[--rawIndex];
            groupCount++;
        }

        return string(out);
    }
}
