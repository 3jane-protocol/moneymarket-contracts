// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";

import {SafeHelper} from "../utils/SafeHelper.sol";

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

    function enableModule(address module) external;
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    function isModuleEnabled(address module) external view returns (bool);
}

interface IAllowanceModule {
    function addDelegate(address delegate) external;

    function setAllowance(
        address delegate,
        address token,
        uint96 allowanceAmount,
        uint16 resetTimeMin,
        uint32 resetBaseMin
    ) external;

    function getTokenAllowance(address safe, address delegate, address token) external view returns (uint256[5] memory);

    function delegates(address safe, uint48 delegateKey)
        external
        view
        returns (address delegate, uint48 prev, uint48 next);
}

interface IMultiSend {
    function multiSend(bytes calldata transactions) external payable;
}

/// @title SetNestedSafeAllowanceSafe
/// @notice Proposes a protocol Safe transaction that makes a nested Safe set the harvest-funding delegate's USDC
///         spending limit on the Safe Allowance Module, enabling the module and registering the delegate first when
///         either is missing.
/// @dev The nested Safe must be owned solely by the protocol Safe at threshold 1, so the protocol Safe calls
///      `execTransaction` on it with a pre-validated owner signature. The nested Safe delegatecalls MultiSendCallOnly
///      with, in order and only where needed, `enableModule(ALLOWANCE_MODULE)`, `addDelegate(DELEGATE)`, and
///      `setAllowance`. The caller supplies the expected current amount so a proposal built against stale state
///      reverts.
/// @dev `resetBaseMin` is minutes since the Unix epoch. Zero keeps an existing allowance's reset anchor and spent
///      amount, or anchors a new allowance at execution time. A nonzero value re-anchors the period to the latest
///      `resetBaseMin + k * resetTimeMin` at or before execution and must not be in the future.
/// @dev Usage:
///      FOUNDRY_PROFILE=script WALLET_TYPE=account SAFE_PROPOSER_ACCOUNT=<account> SAFE_NONCE=<nonce> \
///      yarn script:forge script/operations/SetNestedSafeAllowanceSafe.s.sol:SetNestedSafeAllowanceSafe \
///      --sig "run(address,uint256,uint256,uint16,uint32,bool)" \
///      <nestedSafe> <expectedCurrentAmount> <newAmount> <resetTimeMin> <resetBaseMin> false --rpc-url <rpc-url>
contract SetNestedSafeAllowanceSafe is Script, SafeHelper {
    uint8 private constant CALL = 0;
    uint8 private constant DELEGATECALL = 1;

    address private constant PROTOCOL_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant DELEGATE = 0x318225005B23fF3d9282Ea8eB37a8C9Ce0406540;
    address private constant ALLOWANCE_MODULE = 0xCFbFaC74C26F8647cBDb8c5caf80BB5b32E43134;
    address private constant MULTISEND_CALL_ONLY = 0xA83c336B20401Af773B6219BA5027174338D1836;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    struct TokenAllowance {
        uint256 amount;
        uint256 spent;
        uint256 resetTimeMin;
        uint256 lastResetMin;
        uint256 nonce;
    }

    struct Plan {
        address nestedSafe;
        uint256 newAmount;
        uint16 resetTimeMin;
        uint32 resetBaseMin;
        bool enableModule;
        bool addDelegate;
    }

    function run(
        address nestedSafe,
        uint256 expectedCurrentAmount,
        uint256 newAmount,
        uint16 resetTimeMin,
        uint32 resetBaseMin,
        bool send
    ) external isBatch(PROTOCOL_SAFE) {
        _validateOwnership(nestedSafe);

        TokenAllowance memory before = _allowance(nestedSafe);
        require(before.amount == expectedCurrentAmount, "current allowance differs from expected");
        require(newAmount > 0, "new amount required");
        require(newAmount <= type(uint96).max, "allowance exceeds uint96");
        require(resetBaseMin <= block.timestamp / 60, "reset base in the future");
        require(resetBaseMin == 0 || resetTimeMin > 0, "reset base requires a reset period");

        Plan memory plan = Plan({
            nestedSafe: nestedSafe,
            newAmount: newAmount,
            resetTimeMin: resetTimeMin,
            resetBaseMin: resetBaseMin,
            enableModule: !ISafeLike(nestedSafe).isModuleEnabled(ALLOWANCE_MODULE),
            addDelegate: !_delegateRegistered(nestedSafe)
        });
        bytes memory nestedExecCalldata = _nestedExecCalldata(plan);

        _logPlan(plan, before, nestedExecCalldata, send);

        addToBatch(nestedSafe, nestedExecCalldata);

        require(ISafeLike(nestedSafe).isModuleEnabled(ALLOWANCE_MODULE), "allowance module not enabled");
        require(_delegateRegistered(nestedSafe), "delegate not registered");
        TokenAllowance memory afterward = _allowance(nestedSafe);
        require(afterward.amount == newAmount, "allowance amount not updated");
        require(afterward.resetTimeMin == resetTimeMin, "reset period not updated");
        if (before.nonce != 0) require(afterward.nonce == before.nonce, "allowance nonce changed");
        if (before.nonce != 0 && resetBaseMin == 0) {
            require(afterward.spent == before.spent, "spent amount changed");
            require(afterward.lastResetMin == before.lastResetMin, "reset anchor changed");
        }
        _logAllowance("After (simulated)", afterward);
        console2.log("");

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

    function _nestedExecCalldata(Plan memory plan) private pure returns (bytes memory) {
        bytes memory transactions;
        if (plan.enableModule) {
            transactions = bytes.concat(
                transactions,
                _encodeMultiSendTx(plan.nestedSafe, abi.encodeCall(ISafeLike.enableModule, (ALLOWANCE_MODULE)))
            );
        }
        if (plan.addDelegate) {
            transactions = bytes.concat(
                transactions,
                _encodeMultiSendTx(ALLOWANCE_MODULE, abi.encodeCall(IAllowanceModule.addDelegate, (DELEGATE)))
            );
        }
        transactions = bytes.concat(
            transactions,
            _encodeMultiSendTx(
                ALLOWANCE_MODULE,
                abi.encodeCall(
                    IAllowanceModule.setAllowance,
                    (DELEGATE, USDC, uint96(plan.newAmount), plan.resetTimeMin, plan.resetBaseMin)
                )
            )
        );

        return abi.encodeCall(
            ISafeLike.execTransaction,
            (
                MULTISEND_CALL_ONLY,
                0,
                abi.encodeCall(IMultiSend.multiSend, (transactions)),
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

    function _encodeMultiSendTx(address to, bytes memory data) private pure returns (bytes memory) {
        return abi.encodePacked(CALL, to, uint256(0), data.length, data);
    }

    function _prevalidatedSignature(address owner) private pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    function _allowance(address nestedSafe) private view returns (TokenAllowance memory a) {
        uint256[5] memory raw = IAllowanceModule(ALLOWANCE_MODULE).getTokenAllowance(nestedSafe, DELEGATE, USDC);
        a = TokenAllowance({amount: raw[0], spent: raw[1], resetTimeMin: raw[2], lastResetMin: raw[3], nonce: raw[4]});
    }

    function _delegateRegistered(address nestedSafe) private view returns (bool) {
        (address registered,,) = IAllowanceModule(ALLOWANCE_MODULE).delegates(nestedSafe, uint48(uint160(DELEGATE)));
        return registered == DELEGATE;
    }

    function _validateOwnership(address nestedSafe) private view {
        require(nestedSafe.code.length > 0, "nested safe has no code");
        address[] memory owners = ISafeLike(nestedSafe).getOwners();
        require(owners.length == 1, "unexpected nested safe owner count");
        require(owners[0] == PROTOCOL_SAFE, "protocol safe is not sole nested owner");
        require(ISafeLike(nestedSafe).getThreshold() == 1, "unexpected nested safe threshold");
    }

    function _logPlan(Plan memory plan, TokenAllowance memory before, bytes memory nestedExecCalldata, bool send)
        private
        view
    {
        console2.log("=== Set Nested Safe Allowance ===");
        console2.log("Protocol Safe:", PROTOCOL_SAFE);
        console2.log("Nested Safe:", plan.nestedSafe);
        console2.log("Allowance module:", ALLOWANCE_MODULE);
        console2.log("Delegate:", DELEGATE);
        console2.log("Token (USDC):", USDC);
        console2.log("Enable module:", plan.enableModule);
        console2.log("Add delegate:", plan.addDelegate);
        console2.log("New allowance:", plan.newAmount);
        console2.log("New reset period (minutes):", plan.resetTimeMin);
        console2.log("Reset base (minutes):", plan.resetBaseMin);
        _logAllowance("Before", before);
        console2.log("Nested Safe nonce:", ISafeLike(plan.nestedSafe).nonce());
        console2.log("Protocol Safe nonce:", ISafeLike(PROTOCOL_SAFE).nonce());
        console2.log("Send to Safe:", send);
        console2.log("Nested exec calldata:");
        console2.logBytes(nestedExecCalldata);
        console2.log("");
    }

    function _logAllowance(string memory label, TokenAllowance memory a) private pure {
        console2.log(label);
        console2.log("  amount:", a.amount);
        console2.log("  spent:", a.spent);
        console2.log("  reset period (minutes):", a.resetTimeMin);
        console2.log("  last reset (minutes):", a.lastResetMin);
        console2.log("  nonce:", a.nonce);
    }
}
