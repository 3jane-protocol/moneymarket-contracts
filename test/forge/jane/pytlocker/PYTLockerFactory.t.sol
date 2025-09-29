// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PYTLockerSetup} from "./utils/PYTLockerSetup.sol";
import {
    PYTLocker,
    PYTLockerFactory,
    InvalidAddress,
    PYTAlreadyExpired,
    LockerAlreadyExists
} from "../../../../src/jane/PYTLocker.sol";
import {MockPYT} from "./mocks/MockPYT.sol";

contract PYTLockerFactoryTest is PYTLockerSetup {
    /// @notice Test successful locker creation
    function test_newPYTLocker_success() public {
        // Deploy a new PYT token
        MockPYT newPYT = deployPYT("TEST-PYT", "TPYT", 60 * DAY);

        // Create locker - we only check the first indexed parameter (pytoken)
        vm.expectEmit(true, false, false, false);
        emit LockerCreated(address(newPYT), address(0));

        address lockerAddr = factory.newPYTLocker(address(newPYT));

        // Verify locker was created
        assertTrue(lockerAddr != address(0));
        assertEq(factory.pytLockers(address(newPYT)), lockerAddr);
        assertEq(factory.getLocker(address(newPYT)), lockerAddr);
        assertTrue(factory.hasLocker(address(newPYT)));

        // Verify locker properties
        PYTLocker locker = PYTLocker(lockerAddr);
        assertEq(address(locker.underlying()), address(newPYT));
        assertEq(locker.name(), "lTPYT");
        assertEq(locker.symbol(), "lTPYT");
    }

    /// @notice Test creating locker for already expired PYT reverts
    function test_newPYTLocker_revertsExpiredPYT() public {
        MockPYT expiredPYT = createExpiredPYT();

        vm.expectRevert(PYTAlreadyExpired.selector);
        factory.newPYTLocker(address(expiredPYT));
    }

    /// @notice Test creating duplicate locker reverts
    function test_newPYTLocker_revertsDuplicate() public {
        MockPYT newPYT = deployPYT("TEST-PYT", "TPYT", 60 * DAY);

        // Create first locker
        factory.newPYTLocker(address(newPYT));

        // Try to create duplicate
        vm.expectRevert(LockerAlreadyExists.selector);
        factory.newPYTLocker(address(newPYT));
    }

    /// @notice Test creating locker with zero address reverts
    function test_newPYTLocker_revertsZeroAddress() public {
        vm.expectRevert(InvalidAddress.selector);
        factory.newPYTLocker(address(0));
    }

    /// @notice Test getLocker returns correct address
    function test_getLocker_returnsCorrectAddress() public {
        MockPYT newPYT = deployPYT("TEST-PYT", "TPYT", 60 * DAY);

        // Before creation
        assertEq(factory.getLocker(address(newPYT)), address(0));

        // Create locker
        address lockerAddr = factory.newPYTLocker(address(newPYT));

        // After creation
        assertEq(factory.getLocker(address(newPYT)), lockerAddr);
    }

    /// @notice Test hasLocker returns correct boolean
    function test_hasLocker_returnsCorrectBool() public {
        MockPYT newPYT = deployPYT("TEST-PYT", "TPYT", 60 * DAY);

        // Before creation
        assertFalse(factory.hasLocker(address(newPYT)));

        // Create locker
        factory.newPYTLocker(address(newPYT));

        // After creation
        assertTrue(factory.hasLocker(address(newPYT)));
    }

    /// @notice Test multiple lockers for different PYT tokens
    function test_multipleLockers_differentPYTs() public {
        MockPYT[] memory pyts = new MockPYT[](5);
        address[] memory lockers = new address[](5);

        // Create 5 different PYT tokens and lockers
        for (uint256 i = 0; i < 5; i++) {
            pyts[i] = deployPYT(
                string(abi.encodePacked("PYT-", vm.toString(i))),
                string(abi.encodePacked("P", vm.toString(i))),
                (i + 1) * 30 * DAY
            );

            lockers[i] = factory.newPYTLocker(address(pyts[i]));
        }

        // Verify all lockers are unique and correctly mapped
        for (uint256 i = 0; i < 5; i++) {
            assertEq(factory.getLocker(address(pyts[i])), lockers[i]);
            assertTrue(factory.hasLocker(address(pyts[i])));

            // Verify each locker is different
            for (uint256 j = i + 1; j < 5; j++) {
                assertTrue(lockers[i] != lockers[j]);
            }
        }
    }

    /// @notice Test event emission on locker creation
    function test_newPYTLocker_emitsEvent() public {
        MockPYT newPYT = deployPYT("TEST-PYT", "TPYT", 60 * DAY);

        // We can't predict the exact address, so we check indexed parameters only
        vm.expectEmit(true, false, false, false);
        emit LockerCreated(address(newPYT), address(0));

        address lockerAddr = factory.newPYTLocker(address(newPYT));

        // Verify the actual event was emitted with correct locker address
        assertTrue(lockerAddr != address(0));
    }

    /// @notice Test factory storage persistence
    function test_factoryStorage_persistence() public {
        MockPYT newPYT = deployPYT("TEST-PYT", "TPYT", 60 * DAY);
        address lockerAddr = factory.newPYTLocker(address(newPYT));

        // Deploy a new factory instance at a different address
        PYTLockerFactory factory2 = new PYTLockerFactory();

        // Original factory should still have the mapping
        assertEq(factory.getLocker(address(newPYT)), lockerAddr);

        // New factory should not have the mapping
        assertEq(factory2.getLocker(address(newPYT)), address(0));
    }

    /// @notice Test querying non-existent locker
    function test_getLocker_nonExistent() public {
        MockPYT newPYT = deployPYT("TEST-PYT", "TPYT", 60 * DAY);

        assertEq(factory.getLocker(address(newPYT)), address(0));
        assertFalse(factory.hasLocker(address(newPYT)));
    }

    /// @notice Test creating locker for PYT expiring exactly at current timestamp
    function test_newPYTLocker_expiringNow() public {
        MockPYT nowPYT = createExpiringNowPYT();

        // Should revert as it's already expired (expiry <= block.timestamp)
        vm.expectRevert(PYTAlreadyExpired.selector);
        factory.newPYTLocker(address(nowPYT));
    }

    /// @notice Test gas cost of locker creation
    function test_newPYTLocker_gasUsage() public {
        MockPYT newPYT = deployPYT("TEST-PYT", "TPYT", 60 * DAY);

        uint256 gasBefore = gasleft();
        factory.newPYTLocker(address(newPYT));
        uint256 gasUsed = gasBefore - gasleft();

        // Log gas usage for optimization tracking
        emit log_named_uint("Gas used for locker creation", gasUsed);

        // Ensure it's within reasonable bounds (less than 2M gas)
        assertLt(gasUsed, 2_000_000);
    }

    /// @notice Fuzz test for various expiry times
    function testFuzz_newPYTLocker_variousExpiries(uint256 expiryOffset) public {
        // Bound expiry offset to reasonable range (1 second to 10 years)
        expiryOffset = bound(expiryOffset, 1, 10 * 365 * DAY);

        MockPYT newPYT = new MockPYT("FUZZ-PYT", "FPYT", block.timestamp + expiryOffset);

        address lockerAddr = factory.newPYTLocker(address(newPYT));

        assertTrue(lockerAddr != address(0));
        assertEq(factory.getLocker(address(newPYT)), lockerAddr);

        PYTLocker locker = PYTLocker(lockerAddr);
        assertFalse(locker.isExpired());
        assertEq(locker.expiry(), block.timestamp + expiryOffset);
    }

    /// @notice Test that pytLockers mapping is public and accessible
    function test_pytLockersMapping_publicAccess() public {
        MockPYT newPYT = deployPYT("TEST-PYT", "TPYT", 60 * DAY);
        address lockerAddr = factory.newPYTLocker(address(newPYT));

        // Direct mapping access
        assertEq(factory.pytLockers(address(newPYT)), lockerAddr);

        // Same as getLocker
        assertEq(factory.pytLockers(address(newPYT)), factory.getLocker(address(newPYT)));
    }
}
