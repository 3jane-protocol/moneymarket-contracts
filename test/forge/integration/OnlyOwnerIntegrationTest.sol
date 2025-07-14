// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";

contract OnlyOwnerIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;

    function testDeployWithAddressZero() public {
        MorphoCredit impl = new MorphoCredit();

        // Try to deploy proxy with zero address owner
        bytes memory initData = abi.encodeWithSelector(MorphoCredit.initialize.selector, address(0));
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), initData);
    }

    function testDeployEmitOwner() public {
        MorphoCredit impl = new MorphoCredit();

        // Deploy proxy and expect SetOwner event
        bytes memory initData = abi.encodeWithSelector(MorphoCredit.initialize.selector, OWNER);
        vm.expectEmit();
        emit EventsLib.SetOwner(OWNER);
        new TransparentUpgradeableProxy(address(impl), address(this), initData);
    }

    function testSetOwnerWhenNotOwner(address addressFuzz) public {
        vm.assume(addressFuzz != OWNER);

        vm.prank(addressFuzz);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        morpho.setOwner(addressFuzz);
    }

    function testSetOwnerAlreadySet() public {
        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        morpho.setOwner(OWNER);
    }

    function testSetOwner(address newOwner) public {
        vm.assume(newOwner != OWNER);

        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetOwner(newOwner);
        morpho.setOwner(newOwner);

        assertEq(morpho.owner(), newOwner, "owner is not set");
    }

    function testEnableIrmWhenNotOwner(address addressFuzz, address irmFuzz) public {
        vm.assume(addressFuzz != OWNER);
        vm.assume(irmFuzz != address(irm));

        vm.prank(addressFuzz);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        morpho.enableIrm(irmFuzz);
    }

    function testEnableIrmAlreadySet() public {
        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        morpho.enableIrm(address(irm));
    }

    function testEnableIrm(address irmFuzz) public {
        vm.assume(!morpho.isIrmEnabled(irmFuzz));

        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.EnableIrm(irmFuzz);
        morpho.enableIrm(irmFuzz);

        assertTrue(morpho.isIrmEnabled(irmFuzz), "IRM is not enabled");
    }

    function testEnableLltvWhenNotOwner(address addressFuzz, uint256 lltvFuzz) public {
        vm.assume(addressFuzz != OWNER);
        vm.assume(lltvFuzz != marketParams.lltv);

        vm.prank(addressFuzz);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        morpho.enableLltv(lltvFuzz);
    }

    function testEnableLltvAlreadySet() public {
        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        morpho.enableLltv(marketParams.lltv);
    }

    function testEnableTooHighLltv(uint256 lltv) public {
        lltv = bound(lltv, WAD, type(uint256).max);

        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.MaxLltvExceeded.selector);
        morpho.enableLltv(lltv);
    }

    function testEnableLltv(uint256 lltvFuzz) public {
        lltvFuzz = _boundValidLltv(lltvFuzz);

        vm.assume(!morpho.isLltvEnabled(lltvFuzz));

        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.EnableLltv(lltvFuzz);
        morpho.enableLltv(lltvFuzz);

        assertTrue(morpho.isLltvEnabled(lltvFuzz), "LLTV is not enabled");
    }

    function testSetFeeWhenNotOwner(address addressFuzz, uint256 feeFuzz) public {
        vm.assume(addressFuzz != OWNER);

        vm.prank(addressFuzz);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        morpho.setFee(marketParams, feeFuzz);
    }

    function testSetFeeWhenMarketNotCreated(MarketParams memory marketParamsFuzz, uint256 feeFuzz) public {
        vm.assume(neq(marketParamsFuzz, marketParams));

        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        morpho.setFee(marketParamsFuzz, feeFuzz);
    }

    function testSetTooHighFee(uint256 feeFuzz) public {
        feeFuzz = bound(feeFuzz, MAX_FEE + 1, type(uint256).max);

        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.MaxFeeExceeded.selector);
        morpho.setFee(marketParams, feeFuzz);
    }

    function testSetFee(uint256 feeFuzz) public {
        feeFuzz = bound(feeFuzz, 1, MAX_FEE);

        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetFee(id, feeFuzz);
        morpho.setFee(marketParams, feeFuzz);

        assertEq(morpho.fee(id), feeFuzz);
    }

    function testSetFeeRecipientWhenNotOwner(address addressFuzz) public {
        vm.assume(addressFuzz != OWNER);

        vm.prank(addressFuzz);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        morpho.setFeeRecipient(addressFuzz);
    }

    function testSetFeeRecipient(address newFeeRecipient) public {
        vm.assume(newFeeRecipient != morpho.feeRecipient());

        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetFeeRecipient(newFeeRecipient);
        morpho.setFeeRecipient(newFeeRecipient);

        assertEq(morpho.feeRecipient(), newFeeRecipient);
    }
}
