// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test} from "forge-std/Test.sol";
import {SafeHelper} from "../../../script/utils/SafeHelper.sol";

contract SafeHelperTarget {
    uint256 public value;

    function setValue(uint256 value_) external returns (uint256) {
        value = value_;
        return value_;
    }
}

contract SafeHelperHarness is SafeHelper {
    function configure(address safe_) external {
        _configureSafe(safe_);
    }

    function add(address to_, bytes memory data_) external {
        deployMode = DeployMode.PRODUCTION;
        addToBatch(to_, data_);
    }

    function createBatch(uint256 batchIndex_, uint256 nonce_)
        external
        view
        returns (address to, uint256 value, bytes memory data, Operation operation)
    {
        Batch memory batch = _createBatchFromIndex(batchIndex_, nonce_);
        return (batch.to, batch.value, batch.data, batch.operation);
    }
}

contract SafeHelperTest is Test {
    address private constant SAFE = address(0xBEEF);
    address private constant SAFE_MULTISEND = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;

    SafeHelperHarness private helper;
    SafeHelperTarget private target;

    function setUp() public {
        helper = new SafeHelperHarness();
        helper.configure(SAFE);
        target = new SafeHelperTarget();
    }

    function test_createBatch_usesDirectCallForSingleOperation() public {
        bytes memory callData = abi.encodeCall(SafeHelperTarget.setValue, (42));

        helper.add(address(target), callData);

        (address to, uint256 value, bytes memory data, SafeHelper.Operation operation) = helper.createBatch(0, 1);
        assertEq(to, address(target));
        assertEq(value, 0);
        assertEq(data, callData);
        assertEq(uint256(operation), uint256(SafeHelper.Operation.CALL));
    }

    function test_createBatch_usesMultiSendForMultipleOperations() public {
        helper.add(address(target), abi.encodeCall(SafeHelperTarget.setValue, (1)));
        helper.add(address(target), abi.encodeCall(SafeHelperTarget.setValue, (2)));

        (address to, uint256 value, bytes memory data, SafeHelper.Operation operation) = helper.createBatch(0, 1);
        assertEq(to, SAFE_MULTISEND);
        assertEq(value, 0);
        assertEq(bytes4(data), bytes4(keccak256("multiSend(bytes)")));
        assertEq(uint256(operation), uint256(SafeHelper.Operation.DELEGATECALL));
    }
}
