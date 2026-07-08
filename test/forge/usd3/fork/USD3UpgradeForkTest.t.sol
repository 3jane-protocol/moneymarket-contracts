// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {MainnetForkBase} from "./MainnetForkBase.t.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {USD3_v2} from "../../../../src/usd3/USD3_v2.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {
    ITransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "../../../../lib/openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title USD3UpgradeForkTest
 * @notice Fork tests for the current USD3 cleanup upgrade.
 */
contract USD3UpgradeForkTest is MainnetForkBase {
    function test_currentUpgradePreservesLiveState() public requiresFork {
        ITokenizedStrategy usd3 = ITokenizedStrategy(USD3_PROXY);
        USD3 usd3View = USD3(USD3_PROXY);

        // Pre-upgrade reads are limited to getters that exist on the deployed implementation;
        // supplyCapExempt ships with this upgrade and is only readable afterwards.
        address assetBefore = address(usd3.asset());
        address sUSD3Before = usd3View.sUSD3();
        uint256 minDepositBefore = usd3View.minDeposit();
        uint256 totalAssetsBefore = usd3.totalAssets();
        uint256 totalSupplyBefore = usd3.totalSupply();
        uint256 ppsBefore = totalSupplyBefore == 0 ? 0 : totalAssetsBefore * 1e18 / totalSupplyBefore;
        uint256 navBefore = usd3View.nav();

        assertEq(assetBefore, USDC, "live proxy asset is already USDC");

        // Enable the whitelist gate on the deployed implementation so the deprecated bool slot is genuinely
        // nonzero across the upgrade; the cleaned logic has no gate to read it. The deployed implementation
        // matches the frozen v2 ABI for the whitelist surface.
        address management = usd3.management();
        vm.prank(management);
        USD3_v2(USD3_PROXY).setWhitelistEnabled(true);
        assertEq(usd3.maxDeposit(address(0x1234)), 0, "deployed impl whitelist gate active");

        _upgradeProxyToCleanup();

        assertEq(address(usd3.asset()), assetBefore, "asset preserved");
        assertEq(usd3View.sUSD3(), sUSD3Before, "sUSD3 preserved");
        assertEq(usd3View.minDeposit(), minDepositBefore, "minDeposit preserved");
        assertFalse(usd3View.supplyCapExempt(USD3_PROXY), "new supplyCapExempt mapping starts empty");
        assertFalse(usd3View.supplyCapExempt(WAUSDC), "new supplyCapExempt mapping starts empty");
        assertEq(usd3.totalAssets(), totalAssetsBefore, "totalAssets preserved");
        assertEq(usd3.totalSupply(), totalSupplyBefore, "totalSupply preserved");
        if (totalSupplyBefore > 0) {
            assertEq(usd3.totalAssets() * 1e18 / usd3.totalSupply(), ppsBefore, "PPS preserved");
        }
        assertEq(usd3View.nav(), navBefore, "NAV preserved");

        // The deprecated whitelistEnabled slot still holds true; the cleaned logic must ignore it.
        assertGt(usd3.maxDeposit(address(0x1234)), 0, "deprecated whitelist slots are inert");

        // Exercise a real withdrawal against live mainnet state: sUSD3 is the largest USD3 holder.
        uint256 redeemShares = usd3.maxRedeem(sUSD3Before);
        assertGt(redeemShares, 0, "live holder has withdrawable shares");
        if (redeemShares > 1_000e6) redeemShares = 1_000e6;
        address receiver = makeAddr("forkWithdrawReceiver");
        uint256 usdcBefore = IERC20(USDC).balanceOf(receiver);
        vm.prank(sUSD3Before);
        uint256 withdrawn = usd3.redeem(redeemShares, receiver, sUSD3Before);
        assertGt(withdrawn, 0, "redeem returned assets");
        assertEq(IERC20(USDC).balanceOf(receiver) - usdcBefore, withdrawn, "USDC delivered to receiver");

        console2.log("USD3 fork cleanup upgrade preserved live state");
    }

    function _upgradeProxyToCleanup() internal {
        USD3 newImplementation = new USD3();

        address proxyAdmin = address(uint160(uint256(vm.load(USD3_PROXY, ERC1967Utils.ADMIN_SLOT))));
        address owner = ProxyAdmin(proxyAdmin).owner();

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(USD3_PROXY), address(newImplementation), "");
    }
}
