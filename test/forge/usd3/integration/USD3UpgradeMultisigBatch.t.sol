// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {USD3_old} from "../../../../src/usd3/USD3_old.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "../../../../lib/openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/**
 * @title USD3 Upgrade Multisig Batch Test
 * @notice Tests the current USD3 implementation upgrade from frozen old logic to ring-fence logic.
 */
contract USD3UpgradeMultisigBatchTest is Setup {
    // OZ v5 Initializable ERC-7201 storage location; low 64 bits hold _initialized.
    bytes32 internal constant INITIALIZABLE_STORAGE_SLOT =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    address public alice;

    uint256 public constant INITIAL_DEPOSIT = 1000e6;
    uint256 public constant UPDATED_MIN_DEPOSIT = 250e6;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
    }

    function test_upgradeFromFrozenV2ToCleanupPreservesLiveState() public {
        (USD3_old oldUsd3, ProxyAdmin proxyAdmin, address proxyAdminOwner) = _deployFrozenCurrentProxy();
        setMaxOnCredit(0);

        vm.prank(management);
        oldUsd3.setMinDeposit(UPDATED_MIN_DEPOSIT);

        MockERC20(address(asset)).mint(alice, INITIAL_DEPOSIT + 100e6);
        vm.startPrank(alice);
        asset.approve(address(oldUsd3), INITIAL_DEPOSIT);
        ITokenizedStrategy(address(oldUsd3)).deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // Turn the whitelist gate ON so the deprecated bool slot is genuinely nonzero across the upgrade:
        // the v2 logic must block the non-whitelisted alice, and the cleaned logic must ignore the slot.
        vm.prank(management);
        oldUsd3.setWhitelistEnabled(true);
        assertEq(ITokenizedStrategy(address(oldUsd3)).maxDeposit(alice), 0, "v2 whitelist gate blocks alice");

        // Mirror the live proxy's consumed reinitializer(3): mainnet's version-3 state was written by a
        // transient restart implementation the deployed logic no longer carries, so the storage write is the
        // faithful model.
        vm.store(address(oldUsd3), INITIALIZABLE_STORAGE_SLOT, bytes32(uint256(3)));

        address sUSD3Before = oldUsd3.sUSD3();
        uint256 minDepositBefore = oldUsd3.minDeposit();
        uint256 totalAssetsBefore = ITokenizedStrategy(address(oldUsd3)).totalAssets();
        uint256 totalSupplyBefore = ITokenizedStrategy(address(oldUsd3)).totalSupply();
        uint256 ppsBefore = totalAssetsBefore * 1e18 / totalSupplyBefore;
        uint256 navBefore = oldUsd3.nav();

        _executeUpgradeBatch(proxyAdmin, proxyAdminOwner, address(oldUsd3));

        USD3 upgraded = USD3(address(oldUsd3));

        assertEq(ITokenizedStrategy(address(upgraded)).asset(), address(asset), "asset remains USDC");
        assertEq(upgraded.sUSD3(), sUSD3Before, "sUSD3 preserved");
        assertEq(upgraded.minDeposit(), minDepositBefore, "minDeposit preserved");
        assertFalse(upgraded.supplyCapExempt(alice), "supplyCapExempt defaults false");
        assertEq(upgraded.ringFencedLiquidity(), 0, "ringFencedLiquidity defaults zero");
        assertFalse(upgraded.ringFenceConduit(alice), "ringFenceConduit defaults false");
        assertEq(ITokenizedStrategy(address(upgraded)).totalAssets(), totalAssetsBefore, "totalAssets preserved");
        assertEq(ITokenizedStrategy(address(upgraded)).totalSupply(), totalSupplyBefore, "totalSupply preserved");
        assertEq(
            ITokenizedStrategy(address(upgraded)).totalAssets() * 1e18
                / ITokenizedStrategy(address(upgraded)).totalSupply(),
            ppsBefore,
            "PPS preserved"
        );
        assertEq(upgraded.nav(), navBefore, "NAV preserved");

        assertEq(
            IERC20(address(waUSDC)).allowance(address(upgraded), address(upgraded.morphoCredit())),
            type(uint256).max,
            "waUSDC allowance preserved"
        );
        assertEq(
            IERC20(address(asset)).allowance(address(upgraded), address(waUSDC)),
            type(uint256).max,
            "USDC allowance preserved"
        );

        // The deprecated whitelistEnabled slot still holds true, but the cleaned logic has no gate to read it.
        uint256 limitBeforeDeposit = ITokenizedStrategy(address(upgraded)).maxDeposit(alice);
        assertGt(limitBeforeDeposit, 0, "deprecated whitelist slots are inert");
        assertEq(
            uint256(vm.load(address(upgraded), INITIALIZABLE_STORAGE_SLOT)) & type(uint64).max,
            3,
            "initializer version preserved across upgrade"
        );

        vm.startPrank(alice);
        asset.approve(address(upgraded), 100e6);
        uint256 shares = ITokenizedStrategy(address(upgraded)).deposit(100e6, alice);
        uint256 withdrawn = ITokenizedStrategy(address(upgraded)).redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(withdrawn, 100e6, "post-upgrade deposit/withdraw");
    }

    /// @dev Executes the production batch shape in order: the implementation upgrade first, then the
    ///      governance calls that configure the new logic (they target the upgraded implementation, so
    ///      ordering them before the upgrade would misconfigure or revert).
    function _executeUpgradeBatch(ProxyAdmin proxyAdmin, address proxyAdminOwner, address proxy) internal {
        USD3 newImplementation = new USD3();
        address postUpgradeConduit = makeAddr("postUpgradeConduit");

        vm.prank(proxyAdminOwner);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), address(newImplementation), "");

        assertEq(USD3(proxy).ringFencedLiquidity(), 0, "ringFencedLiquidity starts zero");
        assertFalse(USD3(proxy).ringFenceConduit(postUpgradeConduit), "ringFenceConduit starts false");

        vm.prank(management);
        USD3(proxy).setSupplyCapExempt(postUpgradeConduit, true);

        vm.prank(management);
        USD3(proxy).setRingFenceConduit(postUpgradeConduit, true);

        assertTrue(USD3(proxy).supplyCapExempt(postUpgradeConduit), "post-upgrade supply-cap call applied");
        assertTrue(USD3(proxy).ringFenceConduit(postUpgradeConduit), "post-upgrade ring-fence call applied");
    }

    function _deployFrozenCurrentProxy() internal returns (USD3_old oldUsd3, ProxyAdmin proxyAdmin, address owner) {
        USD3_old oldImplementation = new USD3_old();
        owner = makeAddr("FrozenProxyAdminOwner");

        bytes memory initData = abi.encodeWithSelector(
            USD3_old.initialize.selector,
            address(USD3(address(strategy)).morphoCredit()),
            MarketParamsLib.id(USD3(address(strategy)).marketParams()),
            management,
            keeper
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(oldImplementation), owner, initData);
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT)))));
        oldUsd3 = USD3_old(address(proxy));
        oldUsd3.reinitialize();
    }
}
