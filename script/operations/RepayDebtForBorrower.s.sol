// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IMorpho, Market, Position} from "../../src/interfaces/IMorpho.sol";
import {IHelper} from "../../src/interfaces/IHelper.sol";
import {IERC20, IERC4626} from "../../lib/forge-std/src/interfaces/IERC4626.sol";
import {Id, MarketParams, MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";

contract RepayDebtForBorrower is Script {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using stdJson for string;

    address private constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WAUSDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    address private helper = 0x2A66F992bF227D2e50eF19EDD21503C3c4F3f682;
    MarketParams private marketParams;

    function setUp() public {
        marketParams = IMorpho(MORPHO_CREDIT).idToMarketParams(MARKET_ID);

        require(Id.unwrap(marketParams.id()) == Id.unwrap(MARKET_ID), "Market ID mismatch");
    }

    function run(address borrower, bool send) external {
        run(borrower, type(uint256).max, send);
    }

    function run(address borrower, uint256 usdcAmount, bool send) public {
        setUp();

        address sender = 0x1226858E04b9d077258F153275613734421cD06B;

        console2.log("\n=== Debt Repayment for Borrower ===");
        console2.log("Borrower:", borrower);
        console2.log("Caller:", sender);

        Position memory posBefore = IMorpho(MORPHO_CREDIT).position(MARKET_ID, borrower);
        Market memory market = IMorpho(MORPHO_CREDIT).market(MARKET_ID);

        console2.log("\n--- Before Repayment ---");
        console2.log("Borrow Shares:", posBefore.borrowShares);

        if (posBefore.borrowShares == 0) {
            console2.log("No debt to repay!");
            return;
        }

        uint256 waUsdcDebt =
            uint256(posBefore.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 usdcDebt = IERC4626(WAUSDC).previewRedeem(waUsdcDebt);

        console2.log("waUSDC Debt: %s (6 decimals)", _format(waUsdcDebt, true));
        console2.log("USDC Debt: %s (6 decimals)", _format(usdcDebt, true));

        bool isFullRepayment = (usdcAmount == type(uint256).max);
        uint256 repayAmount = isFullRepayment ? usdcDebt : usdcAmount;

        console2.log("\n--- Repayment Details ---");
        console2.log("Repayment Type:", isFullRepayment ? "Full" : "Partial");
        console2.log("USDC to Pay: %s (6 decimals)", _format(repayAmount, true));

        uint256 callerBalance = IERC20(USDC).balanceOf(sender);
        console2.log("\n--- Caller USDC Balance ---");
        console2.log("Balance: %s (6 decimals)", _format(callerBalance, true));

        if (callerBalance < repayAmount) {
            console2.log("ERROR: Insufficient USDC balance!");
            console2.log("Need: %s", _format(repayAmount, true));
            console2.log("Have: %s", _format(callerBalance, true));
            revert("Insufficient USDC balance");
        }

        uint256 allowance = IERC20(USDC).allowance(sender, helper);
        console2.log("\n--- USDC Allowance to Helper ---");
        console2.log("Current Allowance: %s (6 decimals)", _format(allowance, true));

        if (allowance < repayAmount) {
            console2.log("WARNING: Insufficient allowance!");
            console2.log("Need to approve Helper (%s) for USDC spending", helper);
            console2.log(
                "Run: cast send %s 'approve(address,uint256)' %s %s --private-key <key>",
                USDC,
                helper,
                type(uint256).max
            );
            revert("Insufficient allowance");
        }

        if (!send) {
            console2.log("\n=== DRY RUN - No transaction sent ===");
            console2.log("To execute, run with send=true");
            return;
        }

        console2.log("\n=== Executing Repayment ===");

        vm.startBroadcast();

        (uint256 assetsRepaid, uint256 sharesRepaid) = IHelper(helper).repay(marketParams, usdcAmount, borrower, "");

        vm.stopBroadcast();

        console2.log("\n--- Repayment Results ---");
        console2.log("USDC Paid: %s (6 decimals)", _format(assetsRepaid, true));
        console2.log("Shares Repaid:", sharesRepaid);

        Position memory posAfter = IMorpho(MORPHO_CREDIT).position(MARKET_ID, borrower);
        console2.log("\n--- After Repayment ---");
        console2.log("Remaining Borrow Shares:", posAfter.borrowShares);

        if (posAfter.borrowShares > 0) {
            uint256 waUsdcRemaining =
                uint256(posAfter.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
            uint256 usdcRemaining = IERC4626(WAUSDC).previewRedeem(waUsdcRemaining);
            console2.log("Remaining USDC Debt: %s (6 decimals)", _format(usdcRemaining, true));
        } else {
            console2.log("Debt fully repaid!");
        }

        console2.log("\n=== Repayment Complete ===");
    }

    function _format(uint256 value, bool isUSDC) internal pure returns (string memory) {
        if (isUSDC) {
            uint256 whole = value / 1e6;
            uint256 fraction = value % 1e6;
            return string(abi.encodePacked(vm.toString(whole), ".", _padLeft(vm.toString(fraction), 6)));
        } else {
            return vm.toString(value);
        }
    }

    function _padLeft(string memory str, uint256 length) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (strBytes.length >= length) return str;

        bytes memory result = new bytes(length);
        uint256 padding = length - strBytes.length;

        for (uint256 i = 0; i < padding; i++) {
            result[i] = "0";
        }
        for (uint256 i = 0; i < strBytes.length; i++) {
            result[padding + i] = strBytes[i];
        }

        return string(result);
    }
}
