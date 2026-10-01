// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";

import {IHelper} from "../../src/interfaces/IHelper.sol";
import {IMorpho, Id, Market, MarketParams, Position} from "../../src/interfaces/IMorpho.sol";
import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC4626Like {
    function convertToShares(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
}

/// @notice Fork simulation for:
///         1. executing the already-scheduled credit-line timelock batch through the main Safe
///         2. borrowing 18M USDC from the borrower Safe through HelperV2
contract SimulateExecuteTimelockAndBorrow is Script, TimelockHelper {
    using SharesMathLib for uint256;

    address internal constant BORROWER_SAFE = 0x3Ff3ff33D20a086834A095ed6ed562c9e189291b;
    address internal constant MAIN_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    address internal constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address internal constant MORPHO = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address internal constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address internal constant HELPER = 0x2A66F992bF227D2e50eF19EDD21503C3c4F3f682;
    address internal constant WA_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant IRM = 0x1d434D2899f81F3C3fdf52C814A6E23318f9C7Df;

    Id internal constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);
    bytes32 internal constant MAX_CREDIT_LINE_KEY = 0xd29d3e4fce562a1e66fbe0fbf7c0d4e157eef2b5e8e8c21ba425b1f83eb1fd2c;
    uint256 internal constant DEFAULT_BORROW_USDC = 16_800_000e6;

    function run() external isTimelock(TIMELOCK) {
        _run(DEFAULT_BORROW_USDC);
    }

    function runWithBorrowAmount(uint256 borrowUsdc) external isTimelock(TIMELOCK) {
        _run(borrowUsdc);
    }

    function _run(uint256 borrowUsdc) internal {
        console2.log("=== Simulate Timelock Execute + Helper Borrow ===");
        console2.log("Borrow amount:", borrowUsdc);
        console2.log("Block:", block.number);
        console2.log("Timestamp:", block.timestamp);
        console2.log("");

        _logState("Initial state");

        bytes memory executeCalldata = _executeTimelockCalldata();
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory payloads,
            bytes32 predecessor,
            bytes32 salt
        ) = _decodeExecuteBatch(executeCalldata);

        bytes32 operationId = calculateBatchOperationId(targets, values, payloads, predecessor, salt);
        console2.log("Timelock operation id:", vm.toString(operationId));
        console2.log("Timelock predecessor:", vm.toString(predecessor));
        console2.log("Timelock salt:", vm.toString(salt));
        _logTimelockState(operationId);

        ITimelockController.OperationState state = getOperationState(TIMELOCK, operationId);
        if (state == ITimelockController.OperationState.Waiting) {
            uint256 eta = getOperationTimestamp(TIMELOCK, operationId);
            console2.log("Warping to eta + 1:", eta + 1);
            vm.warp(eta + 1);
        } else if (state == ITimelockController.OperationState.Ready) {
            console2.log("Timelock operation is already ready");
        } else if (state == ITimelockController.OperationState.Done) {
            console2.log("Timelock operation is already done; skipping execute");
            _borrow(borrowUsdc);
            return;
        } else {
            revert("Timelock operation is not scheduled");
        }

        console2.log("");
        console2.log("Executing timelock as main Safe:", MAIN_SAFE);
        vm.prank(MAIN_SAFE);
        (bool success, bytes memory returnData) = TIMELOCK.call(executeCalldata);
        if (!success) {
            console2.log("Timelock execute failed:");
            console2.logBytes(returnData);
            revert("timelock execute failed");
        }

        _logState("After timelock execution");
        _borrow(borrowUsdc);
    }

    function _borrow(uint256 borrowUsdc) internal {
        MarketParams memory marketParams = _marketParams();
        uint256 helperWaUsdcArgument = IERC4626Like(WA_USDC).convertToShares(borrowUsdc);
        uint256 balanceBefore = IERC20Like(USDC).balanceOf(BORROWER_SAFE);

        console2.log("");
        console2.log("Borrowing via HelperV2 as borrower Safe:", BORROWER_SAFE);
        console2.log("Requested USDC amount:", borrowUsdc);
        console2.log("Helper convertToShares argument:", helperWaUsdcArgument);

        vm.prank(BORROWER_SAFE);
        try IHelper(HELPER).borrow(marketParams, borrowUsdc, bytes32(0)) returns (
            uint256 usdcReceived, uint256 shares
        ) {
            uint256 balanceAfter = IERC20Like(USDC).balanceOf(BORROWER_SAFE);
            console2.log("Borrow succeeded");
            console2.log("USDC received:", usdcReceived);
            console2.log("Borrow shares minted:", shares);
            console2.log("USDC balance delta:", balanceAfter - balanceBefore);
            _logState("After helper borrow");
        } catch (bytes memory reason) {
            console2.log("Borrow failed:");
            console2.logBytes(reason);
            revert("helper borrow failed");
        }
    }

    function _logState(string memory label) internal view {
        Position memory position = IMorpho(MORPHO).position(MARKET_ID, BORROWER_SAFE);
        Market memory market = IMorpho(MORPHO).market(MARKET_ID);

        uint256 debt = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 remainingCredit = uint256(position.collateral) > debt ? uint256(position.collateral) - debt : 0;
        uint256 availableWaUsdc = market.totalSupplyAssets > market.totalBorrowAssets
            ? uint256(market.totalSupplyAssets) - uint256(market.totalBorrowAssets)
            : 0;

        console2.log("");
        console2.log("===", label, "===");
        console2.log("credit line waEthUSDC:", uint256(position.collateral));
        console2.log("credit line preview USDC:", IERC4626Like(WA_USDC).previewRedeem(position.collateral));
        console2.log("borrow shares:", uint256(position.borrowShares));
        console2.log("borrow assets waEthUSDC:", debt);
        console2.log("borrow assets preview USDC:", IERC4626Like(WA_USDC).previewRedeem(debt));
        console2.log("remaining credit waEthUSDC:", remainingCredit);
        console2.log("remaining credit preview USDC:", IERC4626Like(WA_USDC).previewRedeem(remainingCredit));
        console2.log("available liquidity waEthUSDC:", availableWaUsdc);
        console2.log("available liquidity preview USDC:", IERC4626Like(WA_USDC).previewRedeem(availableWaUsdc));
        console2.log("MAX_CREDIT_LINE:", IProtocolConfig(PROTOCOL_CONFIG).config(MAX_CREDIT_LINE_KEY));
        console2.log("borrower USDC balance:", IERC20Like(USDC).balanceOf(BORROWER_SAFE));
    }

    function _logTimelockState(bytes32 operationId) internal view {
        ITimelockController.OperationState state = getOperationState(TIMELOCK, operationId);
        console2.log("Timelock state enum:", uint256(state));
        if (state == ITimelockController.OperationState.Waiting) {
            uint256 eta = getOperationTimestamp(TIMELOCK, operationId);
            console2.log("Ready at:", eta);
            console2.log("Seconds remaining:", eta > block.timestamp ? eta - block.timestamp : 0);
        }
    }

    function _decodeExecuteBatch(bytes memory executeCalldata)
        internal
        pure
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory payloads,
            bytes32 predecessor,
            bytes32 salt
        )
    {
        bytes4 selector;
        assembly {
            selector := mload(add(executeCalldata, 0x20))
        }
        require(selector == ITimelockController.executeBatch.selector, "unexpected execute selector");
        bytes memory args = _stripSelector(executeCalldata);
        return abi.decode(args, (address[], uint256[], bytes[], bytes32, bytes32));
    }

    function _stripSelector(bytes memory data) internal pure returns (bytes memory stripped) {
        require(data.length >= 4, "calldata too short");
        stripped = new bytes(data.length - 4);
        for (uint256 i; i < stripped.length; ++i) {
            stripped[i] = data[i + 4];
        }
    }

    function _marketParams() internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: WA_USDC,
            collateralToken: USDC,
            oracle: address(0),
            irm: IRM,
            lltv: 999999999999999999,
            creditLine: CREDIT_LINE
        });
    }

    function _executeTimelockCalldata() internal pure returns (bytes memory) {
        return hex"e38335e500000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001a00000000000000000000000000000000000000000000000000000000000000000209c07a38205f05079bcd6b7b62ef98e8920df24f3c638e89d18c9c92d2f38e100000000000000000000000000000000000000000000000000000000000000030000000000000000000000006b276a2a7dd8b629adba8a06ad6573d01c84f34e00000000000000000000000026389b03298ba5da0664ffd6bf78cf3a7820c6a90000000000000000000000006b276a2a7dd8b629adba8a06ad6573d01c84f34e00000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000004415fe96dcd29d3e4fce562a1e66fbe0fbf7c0d4e157eef2b5e8e8c21ba425b1f83eb1fd2c0000000000000000000000000000000000000000000000000000228f908060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001e49770e36e00000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a00000000000000000000000000000000000000000000000000000000000000001c2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d7500000000000000000000000000000000000000000000000000000000000000010000000000000000000000003ff3ff33d20a086834a095ed6ed562c9e189291b000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000006d23ad5f800000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000228f908060000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004415fe96dcd29d3e4fce562a1e66fbe0fbf7c0d4e157eef2b5e8e8c21ba425b1f83eb1fd2c000000000000000000000000000000000000000000000000000000c61e4140a100000000000000000000000000000000000000000000000000000000";
    }
}
