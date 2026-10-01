// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";

import {SafeHelper} from "../utils/SafeHelper.sol";
import {MarketParams} from "../../src/interfaces/IMorpho.sol";

interface ISafeLike {
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);

    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
}

interface IERC20Transfer {
    function transfer(address to, uint256 value) external returns (bool);
}

interface IHelperBorrow {
    function borrow(MarketParams memory marketParams, uint256 assets, bytes32 referral)
        external
        returns (uint256, uint256);
}

interface IMultiSend {
    function multiSend(bytes calldata transactions) external payable;
}

/// @title BorrowAndSendToEreborSafe
/// @notice Queues a protocol Safe transaction that makes the nested borrower Safe borrow USDC and send it to Erebor.
/// @dev The input amount is the desired USDC transfer amount. The helper borrow uses transfer amount + 1 raw USDC unit.
contract BorrowAndSendToEreborSafe is Script, SafeHelper {
    uint8 private constant CALL = 0;
    uint8 private constant DELEGATECALL = 1;

    address private constant PROTOCOL_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant BORROWER_SAFE = 0x3Ff3ff33D20a086834A095ed6ed562c9e189291b;
    address private constant EREBOR_DEPOSIT = 0x3835350170DB8E093576FAB23D5B934FbbB9A42E;

    address private constant MULTISEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address private constant HELPER = 0x2A66F992bF227D2e50eF19EDD21503C3c4F3f682;
    address private constant WA_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant IRM = 0x1d434D2899f81F3C3fdf52C814A6E23318f9C7Df;
    address private constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;

    function run(uint256 transferUsdc) external {
        this.run(transferUsdc, false);
    }

    function run(uint256 transferUsdc, bool send) external isBatch(PROTOCOL_SAFE) {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        _validateNestedSafeOwnership();

        uint256 borrowUsdc = _borrowAmount(transferUsdc);
        bytes memory nestedExecCalldata = _nestedExecCalldata(transferUsdc);

        _logPlan("Queue Nested Borrow + Erebor Transfer", transferUsdc, borrowUsdc, nestedExecCalldata, send);

        addToBatch(BORROWER_SAFE, nestedExecCalldata);

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully.");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    function preview(uint256 transferUsdc) external view {
        _validateNestedSafeOwnership();

        uint256 borrowUsdc = _borrowAmount(transferUsdc);
        bytes memory nestedExecCalldata = _nestedExecCalldata(transferUsdc);
        _logPlan("Preview Nested Borrow + Erebor Transfer", transferUsdc, borrowUsdc, nestedExecCalldata, false);
    }

    function calldataFor(uint256 transferUsdc) external view returns (bytes memory) {
        _validateNestedSafeOwnership();
        return _nestedExecCalldata(transferUsdc);
    }

    function _nestedExecCalldata(uint256 transferUsdc) private pure returns (bytes memory) {
        uint256 borrowUsdc = _borrowAmount(transferUsdc);
        bytes memory borrowCall = abi.encodeCall(IHelperBorrow.borrow, (_marketParams(), borrowUsdc, bytes32(0)));
        bytes memory transferCall = abi.encodeCall(IERC20Transfer.transfer, (EREBOR_DEPOSIT, transferUsdc));
        bytes memory multiSendTxs = bytes.concat(
            _encodeMultiSendTx(CALL, HELPER, 0, borrowCall), _encodeMultiSendTx(CALL, USDC, 0, transferCall)
        );
        bytes memory multiSendCall = abi.encodeCall(IMultiSend.multiSend, (multiSendTxs));

        return abi.encodeCall(
            ISafeLike.execTransaction,
            (
                MULTISEND_CALL_ONLY,
                0,
                multiSendCall,
                DELEGATECALL,
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                _prevalidatedSignature(PROTOCOL_SAFE)
            )
        );
    }

    function _encodeMultiSendTx(uint8 operation, address to, uint256 value, bytes memory data)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(operation, to, value, data.length, data);
    }

    function _prevalidatedSignature(address owner) private pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    function _borrowAmount(uint256 transferUsdc) private pure returns (uint256) {
        require(transferUsdc > 0, "transfer amount required");
        return transferUsdc + 1;
    }

    function _marketParams() private pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: WA_USDC,
            collateralToken: USDC,
            oracle: address(0),
            irm: IRM,
            lltv: 999999999999999999,
            creditLine: CREDIT_LINE
        });
    }

    function _validateNestedSafeOwnership() private view {
        address[] memory owners = ISafeLike(BORROWER_SAFE).getOwners();
        require(owners.length == 1, "unexpected nested safe owner count");
        require(owners[0] == PROTOCOL_SAFE, "protocol safe is not sole nested owner");
        require(ISafeLike(BORROWER_SAFE).getThreshold() == 1, "unexpected nested safe threshold");
    }

    function _logPlan(
        string memory label,
        uint256 transferUsdc,
        uint256 borrowUsdc,
        bytes memory nestedExecCalldata,
        bool send
    ) private view {
        console2.log("===", label, "===");
        console2.log("Protocol Safe:", PROTOCOL_SAFE);
        console2.log("Nested Borrower Safe:", BORROWER_SAFE);
        console2.log("Erebor deposit:", EREBOR_DEPOSIT);
        console2.log("Helper:", HELPER);
        console2.log("USDC:", USDC);
        console2.log("Transfer amount:", transferUsdc);
        console2.log("Borrow amount:", borrowUsdc);
        console2.log("Nested Safe nonce:", ISafeLike(BORROWER_SAFE).nonce());
        console2.log("Protocol Safe nonce:", ISafeLike(PROTOCOL_SAFE).nonce());
        console2.log("Send to Safe:", send);
        console2.log("Nested exec calldata:");
        console2.logBytes(nestedExecCalldata);
        console2.log("");
    }

    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee too high: %d gwei > %d gwei limit", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        console2.log("Base fee OK: %d gwei", block.basefee / 1e9);
        return true;
    }
}
