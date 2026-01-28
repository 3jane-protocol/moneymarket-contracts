// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";

/// @title CallableCreditUnitTest
/// @notice Unit tests for CallableCredit constructor, authorization, and modifiers
contract CallableCreditUnitTest is CallableCreditBaseTest {
    // ============ Constructor Tests ============

    function testConstructorRevertsZeroMorpho() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new CallableCredit(address(0), ccMarketId);
    }

    function testConstructorRevertsMarketNotCreated() public {
        // Use a non-existent market ID
        Id fakeMarketId = Id.wrap(keccak256("fake-market"));
        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        new CallableCredit(address(morpho), fakeMarketId);
    }

    function testImmutablesSetCorrectly() public view {
        assertEq(address(callableCredit.MORPHO()), address(morpho));
        assertEq(address(callableCredit.WAUSDC()), address(wausdc));
        assertEq(address(callableCredit.USDC()), address(usdc));
        assertEq(address(callableCredit.PROTOCOL_CONFIG()), address(protocolConfig));
        assertEq(Id.unwrap(callableCredit.MARKET_ID()), Id.unwrap(ccMarketId));
    }

    function testMarketParamsReconstruction() public view {
        MarketParams memory reconstructed = callableCredit.marketParams();
        assertEq(reconstructed.loanToken, ccMarketParams.loanToken);
        assertEq(reconstructed.collateralToken, ccMarketParams.collateralToken);
        assertEq(reconstructed.oracle, ccMarketParams.oracle);
        assertEq(reconstructed.irm, ccMarketParams.irm);
        assertEq(reconstructed.lltv, ccMarketParams.lltv);
        assertEq(reconstructed.creditLine, ccMarketParams.creditLine);
    }

    // ============ Ownership Tests ============

    function testOwnerInheritedFromMorpho() public view {
        assertEq(callableCredit.owner(), OWNER);
        assertEq(callableCredit.owner(), morpho.owner());
    }

    function testOwnerChangesWithMorpho() public {
        address newOwner = makeAddr("NewOwner");

        vm.prank(OWNER);
        morpho.setOwner(newOwner);

        assertEq(callableCredit.owner(), newOwner);
    }

    // ============ Authorization Tests ============

    function testSetAuthorizedOnlyOwner() public {
        address randomUser = makeAddr("RandomUser");

        vm.prank(randomUser);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        callableCredit.setAuthorizedCounterProtocol(COUNTER_PROTOCOL_2, true);
    }

    function testSetAuthorizedSuccess() public {
        assertFalse(callableCredit.authorizedCounterProtocols(COUNTER_PROTOCOL_2));

        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit ICallableCredit.CounterProtocolAuthorized(COUNTER_PROTOCOL_2, true);
        callableCredit.setAuthorizedCounterProtocol(COUNTER_PROTOCOL_2, true);

        assertTrue(callableCredit.authorizedCounterProtocols(COUNTER_PROTOCOL_2));
    }

    function testRevokeAuthorization() public {
        // First authorize
        vm.prank(OWNER);
        callableCredit.setAuthorizedCounterProtocol(COUNTER_PROTOCOL_2, true);
        assertTrue(callableCredit.authorizedCounterProtocols(COUNTER_PROTOCOL_2));

        // Then revoke
        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit ICallableCredit.CounterProtocolAuthorized(COUNTER_PROTOCOL_2, false);
        callableCredit.setAuthorizedCounterProtocol(COUNTER_PROTOCOL_2, false);

        assertFalse(callableCredit.authorizedCounterProtocols(COUNTER_PROTOCOL_2));
    }

    // ============ Freeze Modifier Tests ============

    function testOpenRevertsWhenFrozen() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _freezeCallableCredit();

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.CallableCreditFrozen.selector);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
    }

    function testCloseRevertsWhenFrozen() public {
        // First open a position
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Then freeze
        _freezeCallableCredit();

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.CallableCreditFrozen.selector);
        callableCredit.close(BORROWER_1);
    }

    function testDrawRevertsWhenFrozen() public {
        // First open a position
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Then freeze
        _freezeCallableCredit();

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.CallableCreditFrozen.selector);
        callableCredit.draw(BORROWER_1, 10_000e6, RECIPIENT);
    }

    function testProRataDrawRevertsWhenFrozen() public {
        // First open a position
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Then freeze
        _freezeCallableCredit();

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.CallableCreditFrozen.selector);
        callableCredit.draw(10_000e6, RECIPIENT);
    }

    // ============ Not Authorized Tests ============

    function testOpenRevertsNotAuthorized() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        address unauthorized = makeAddr("Unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(ErrorsLib.NotAuthorizedCounterProtocol.selector);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
    }

    function testCloseRevertsNotAuthorized() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        address unauthorized = makeAddr("Unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(ErrorsLib.NotAuthorizedCounterProtocol.selector);
        callableCredit.close(BORROWER_1);
    }

    function testDrawRevertsNotAuthorized() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        address unauthorized = makeAddr("Unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(ErrorsLib.NotAuthorizedCounterProtocol.selector);
        callableCredit.draw(BORROWER_1, 10_000e6, RECIPIENT);
    }

    function testProRataDrawRevertsNotAuthorized() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        address unauthorized = makeAddr("Unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(ErrorsLib.NotAuthorizedCounterProtocol.selector);
        callableCredit.draw(10_000e6, RECIPIENT);
    }
}
