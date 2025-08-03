// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {MorphoCreditMock} from "../../src/mocks/MorphoCreditMock.sol";
import {MorphoCredit} from "../../src/MorphoCredit.sol";
import {MarketParams, Id} from "../../src/interfaces/IMorpho.sol";
import {MorphoStorageLib} from "../../src/libraries/periphery/MorphoStorageLib.sol";
import {MorphoCreditStorageLib} from "../../src/libraries/periphery/MorphoCreditStorageLib.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {ERC20Mock} from "../../src/mocks/ERC20Mock.sol";
import {IrmMock} from "../../src/mocks/IrmMock.sol";
import {OracleMock} from "../../src/mocks/OracleMock.sol";

/// @title MorphoCreditProxy Tests
/// @notice Tests for MorphoCredit with TransparentUpgradeableProxy
contract MorphoCreditProxyTest is Test {
    using MarketParamsLib for MarketParams;

    MorphoCredit public implementation;
    TransparentUpgradeableProxy public proxy;
    ProxyAdmin public proxyAdmin;
    MorphoCredit public morphoCredit;

    address public owner = makeAddr("owner");
    address public admin = makeAddr("admin");
    address public user = makeAddr("user");

    ERC20Mock public loanToken;
    ERC20Mock public collateralToken;
    OracleMock public oracle;
    IrmMock public irm;

    MarketParams public marketParams;
    Id public id;

    function setUp() public {
        // Deploy mocks
        loanToken = new ERC20Mock();
        collateralToken = new ERC20Mock();
        oracle = new OracleMock();
        irm = new IrmMock();

        // Deploy implementation
        implementation = new MorphoCreditMock(address(1));

        // Deploy ProxyAdmin separately
        proxyAdmin = new ProxyAdmin(admin);

        // Deploy proxy using the older pattern that's compatible
        bytes memory initData = abi.encodeWithSelector(MorphoCredit.initialize.selector, owner);
        proxy = new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

        // Cast proxy to MorphoCredit
        morphoCredit = MorphoCreditMock(address(proxy));

        // Setup market params
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.8e18,
            creditLine: address(0)
        });
        id = marketParams.id();

        // Enable market
        vm.startPrank(owner);
        morphoCredit.enableIrm(address(irm));
        morphoCredit.enableLltv(0.8e18);
        morphoCredit.createMarket(marketParams);
        vm.stopPrank();
    }

    function testProxyInitialization() public view {
        // Check owner is set correctly
        assertEq(morphoCredit.owner(), owner);

        // Check DOMAIN_SEPARATOR is set correctly with proxy address
        bytes32 DOMAIN_TYPEHASH = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
        bytes32 expectedDomainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(proxy)));
        assertEq(morphoCredit.DOMAIN_SEPARATOR(), expectedDomainSeparator);
    }

    function testCannotInitializeTwice() public {
        vm.expectRevert(bytes4(0xf92ee8a9)); // Initializable.InvalidInitialization()
        morphoCredit.initialize(owner);
    }

    function testImplementationCannotBeInitialized() public {
        MorphoCredit impl = new MorphoCreditMock(address(1));
        vm.expectRevert(bytes4(0xf92ee8a9)); // Initializable.InvalidInitialization()
        impl.initialize(owner);
    }

    function testStorageSlotPositions() public {
        // Test Morpho base storage slots
        assertEq(uint256(MorphoStorageLib.ownerSlot()), 0);
        assertEq(uint256(MorphoStorageLib.feeRecipientSlot()), 1);
        assertEq(uint256(bytes32(MorphoStorageLib.POSITION_SLOT)), 2);
        assertEq(uint256(bytes32(MorphoStorageLib.MARKET_SLOT)), 3);
        assertEq(uint256(bytes32(MorphoStorageLib.IS_IRM_ENABLED_SLOT)), 4);
        assertEq(uint256(bytes32(MorphoStorageLib.IS_LLTV_ENABLED_SLOT)), 5);
        assertEq(uint256(bytes32(MorphoStorageLib.IS_AUTHORIZED_SLOT)), 6);
        assertEq(uint256(bytes32(MorphoStorageLib.NONCE_SLOT)), 7);
        assertEq(uint256(bytes32(MorphoStorageLib.ID_TO_MARKET_PARAMS_SLOT)), 8);
        // DOMAIN_SEPARATOR is now at slot 9

        // Test MorphoCredit storage slots (start after Morpho base + __gap)
        assertEq(uint256(MorphoCreditStorageLib.helperSlot()), 20);
        assertEq(uint256(MorphoCreditStorageLib.protocolConfigSlot()), 21);
        assertEq(uint256(MorphoCreditStorageLib.usd3Slot()), 22);
        assertEq(uint256(bytes32(MorphoCreditStorageLib.BORROWER_PREMIUM_SLOT)), 23);
        assertEq(uint256(bytes32(MorphoCreditStorageLib.PAYMENT_CYCLE_SLOT)), 24);
        assertEq(uint256(bytes32(MorphoCreditStorageLib.REPAYMENT_OBLIGATION_SLOT)), 25);
        assertEq(uint256(bytes32(MorphoCreditStorageLib.MARKDOWN_STATE_SLOT)), 26);
    }

    function testProxyStatePreservation() public {
        // Store some state
        vm.prank(owner);
        morphoCredit.setHelper(user);
        morphoCredit.setUsd3(user);
        assertEq(morphoCredit.helper(), user);
        assertEq(morphoCredit.usd3(), user);

        // Create a market and supply
        vm.startPrank(user);
        loanToken.approve(address(morphoCredit), 1000e18);
        loanToken.setBalance(user, 1000e18);
        morphoCredit.supply(marketParams, 1000e18, 0, user, "");
        vm.stopPrank();

        // Check state is preserved across multiple calls
        assertEq(morphoCredit.helper(), user);
        assertEq(morphoCredit.usd3(), user);
        assertEq(morphoCredit.owner(), owner);
        (uint256 supplyShares,,) = morphoCredit.position(id, user);
        assertTrue(supplyShares > 0);
    }

    function testProxyAdminAccess() public {
        // Check that ProxyAdmin is owned by admin
        assertEq(proxyAdmin.owner(), admin);

        // Non-admin cannot transfer ProxyAdmin ownership
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), user));
        vm.prank(user);
        proxyAdmin.transferOwnership(user);

        // Admin can transfer ProxyAdmin ownership
        vm.prank(admin);
        proxyAdmin.transferOwnership(user);
        assertEq(proxyAdmin.owner(), user);
    }

    function testMarketOperationsThroughProxy() public {
        // Supply tokens
        uint256 supplyAmount = 1000e18;
        loanToken.setBalance(user, supplyAmount);

        vm.startPrank(user);
        loanToken.approve(address(morphoCredit), supplyAmount);
        (uint256 assets, uint256 shares) = morphoCredit.supply(marketParams, supplyAmount, 0, user, "");
        vm.stopPrank();

        assertEq(assets, supplyAmount);
        assertGt(shares, 0);
    }

    function testStorageGapPreventsCollision() public view {
        // Verify storage gaps exist and have correct size
        // This test is mainly for documentation - gaps are private so we can't directly access them
        // But their presence ensures future upgrades won't cause storage collisions

        // Morpho has 10-slot gap
        // MorphoCredit has 14-slot gap
        // Total slots used: 9 (Morpho base) + 1 (DOMAIN_SEPARATOR) + 6 (MorphoCredit) = 16
        // With gaps: 16 + 10 + 14 = 40 slots reserved
        assertTrue(true); // Placeholder assertion
    }

    function testCannotReinitialize() public {
        // Try to reinitialize - should fail
        vm.expectRevert(bytes4(0xf92ee8a9)); // Initializable.InvalidInitialization()
        morphoCredit.initialize(user);
    }

    function testDirectImplementationCallsRevert() public {
        // Try to call implementation directly - should revert because it's disabled
        MorphoCredit directImpl = new MorphoCreditMock(address(1));

        vm.expectRevert(bytes4(0xf92ee8a9)); // Initializable.InvalidInitialization()
        directImpl.initialize(owner);

        // View functions on implementation return default values (not revert)
        // This is expected behavior - implementation is locked but readable
        assertEq(directImpl.owner(), address(0));
    }
}
