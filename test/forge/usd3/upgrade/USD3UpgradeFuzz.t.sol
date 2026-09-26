// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {USD3_old} from "../../../../src/usd3/USD3_old.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {IMorpho, Position} from "../../../../src/interfaces/IMorpho.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ITransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title USD3 Upgrade Fuzz Test
 * @notice Fuzzes live frozen-v2 state and proves that the cleanup implementation upgrade is state preserving.
 */
contract USD3UpgradeFuzzTest is Setup {
    uint256 internal constant DEPRECATED_WHITELIST_ENABLED_SLOT = 58;
    uint256 internal constant DEPRECATED_WHITELIST_SLOT = 59;
    uint256 internal constant DEPRECATED_DEPOSIT_TIMESTAMP_SLOT = 62;

    uint256 internal constant MIN_DEPOSIT = 10_000e6;
    uint256 internal constant MAX_DEPOSIT = 1_000_000e6;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CHARLIE = address(0xCA11E);
    address internal constant INERT_PROBE = address(0x1E47);
    address internal constant SHARE_SPENDER = address(0x5EED);

    struct FuzzState {
        uint256[3] deposits;
        uint256[3] residualBalances;
        uint256[3] shareAllowances;
        uint256[3] assetAllowances;
        bool[3] whitelisted;
        bool whitelistEnabled;
        uint256 waUsdcSharePrice;
        uint256 profitMaxUnlockTime;
        uint256 profitUnlockElapsed;
        uint256 commitmentTime;
        uint256 firstDepositTimestamp;
        uint256 depositTimestampStep;
        uint256 maxOnCredit;
    }

    struct UserSnapshot {
        uint256[3] shareBalances;
        uint256[3] assetBalances;
        uint256[3] shareAllowances;
        uint256[3] assetAllowances;
        bytes32[3] whitelistEntries;
        bytes32[3] depositTimestampEntries;
    }

    struct StrategySnapshot {
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 pricePerShare;
        uint256 nav;
        uint256 localWaUsdc;
        uint256 suppliedWaUsdc;
        uint256 morphoWaUsdcBalance;
        uint256 waUsdcAllowance;
        uint256 assetAllowance;
        uint256 profitMaxUnlockTime;
        uint256 fullProfitUnlockDate;
        uint256 profitUnlockingRate;
        uint256 lastReport;
        uint256 unlockedShares;
        Position morphoPosition;
        bytes32 initializerWord;
        bytes32 deprecatedWhitelistEnabledWord;
    }

    function testFuzz_upgradePreservesRandomizedLiveState(
        bytes32 seed,
        bool whitelistEnabled,
        address supplyCapProbe,
        address ringFenceProbe
    ) public {
        FuzzState memory fuzzState = _deriveFuzzState(seed, whitelistEnabled);
        address[3] memory users = _users();

        (USD3_old oldUsd3, ProxyAdmin proxyAdmin, address proxyAdminOwner) = _deployUpgradeTarget();
        _seedLiveState(oldUsd3, users, fuzzState);
        _forceMainnetInitializerVersion(address(oldUsd3));

        UserSnapshot memory usersBefore = _snapshotUsers(oldUsd3, users);
        StrategySnapshot memory strategyBefore = _snapshotStrategy(oldUsd3);

        USD3 newImplementation = new USD3();
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(oldUsd3)), address(newImplementation), bytes(""));

        USD3 upgraded = USD3(address(oldUsd3));
        _assertUsersPreserved(upgraded, users, usersBefore);
        _assertStrategyPreserved(upgraded, strategyBefore);
        _assertDeprecatedStatePreservedAndInert(upgraded, users, usersBefore, strategyBefore);

        assertFalse(upgraded.supplyCapExempt(supplyCapProbe), "supplyCapExempt default");
        assertFalse(upgraded.ringFenceConduit(ringFenceProbe), "ringFenceConduit default");
        assertEq(upgraded.ringFencedLiquidity(), 0, "ringFencedLiquidity default");

        assertEq(
            uint256(vm.load(address(upgraded), INITIALIZABLE_STORAGE_SLOT)) & type(uint64).max, 3, "initializer version"
        );
        vm.expectRevert("initialized");
        ITokenizedStrategy(address(upgraded))
            .initialize(address(asset), "USD3 reinitialize attempt", management, performanceFeeRecipient, keeper);
    }

    function _deriveFuzzState(bytes32 seed, bool whitelistEnabled) internal returns (FuzzState memory fuzzState) {
        for (uint256 i; i < 3; ++i) {
            fuzzState.deposits[i] = bound(_random(seed, i), MIN_DEPOSIT, MAX_DEPOSIT);
            fuzzState.residualBalances[i] = bound(_random(seed, i + 3), 0, 500_000e6);
            fuzzState.shareAllowances[i] = bound(_random(seed, i + 6), 0, 2 * MAX_DEPOSIT);
            fuzzState.assetAllowances[i] = bound(_random(seed, i + 9), 0, MAX_DEPOSIT);
        }

        fuzzState.whitelisted[0] = (_random(seed, 12) & 1) == 1;
        fuzzState.whitelisted[1] = !fuzzState.whitelisted[0];
        fuzzState.whitelisted[2] = (_random(seed, 13) & 1) == 1;
        fuzzState.whitelistEnabled = whitelistEnabled;
        fuzzState.waUsdcSharePrice = bound(_random(seed, 14), 1_000_001, 1_750_000);
        fuzzState.profitMaxUnlockTime = bound(_random(seed, 15), 4 days, 30 days);
        fuzzState.profitUnlockElapsed =
            bound(_random(seed, 16), fuzzState.profitMaxUnlockTime / 4, 3 * fuzzState.profitMaxUnlockTime / 4);
        fuzzState.commitmentTime = bound(_random(seed, 17), 180 days, 365 days);
        fuzzState.firstDepositTimestamp = bound(_random(seed, 18), 1_000 days, 10_000 days);
        fuzzState.depositTimestampStep = bound(_random(seed, 19), 1, 1 days);
        fuzzState.maxOnCredit = bound(_random(seed, 20), 2_000, 8_000);
    }

    function _seedLiveState(USD3_old oldUsd3, address[3] memory users, FuzzState memory fuzzState) internal {
        testProtocolConfig.setConfig(keccak256("USD3_COMMITMENT_TIME"), fuzzState.commitmentTime);
        setMaxOnCredit(fuzzState.maxOnCredit);

        for (uint256 i; i < users.length; ++i) {
            vm.warp(fuzzState.firstDepositTimestamp + i * fuzzState.depositTimestampStep);
            MockERC20(address(asset)).mint(users[i], fuzzState.deposits[i] + fuzzState.residualBalances[i]);

            vm.startPrank(users[i]);
            asset.approve(address(oldUsd3), fuzzState.deposits[i]);
            ITokenizedStrategy(address(oldUsd3)).deposit(fuzzState.deposits[i], users[i]);
            ITokenizedStrategy(address(oldUsd3)).approve(SHARE_SPENDER, fuzzState.shareAllowances[i]);
            asset.approve(address(oldUsd3), fuzzState.assetAllowances[i]);
            vm.stopPrank();

            vm.prank(management);
            oldUsd3.setWhitelist(users[i], fuzzState.whitelisted[i]);
        }

        vm.prank(management);
        oldUsd3.setWhitelist(INERT_PROBE, false);
        vm.prank(management);
        oldUsd3.setWhitelistEnabled(fuzzState.whitelistEnabled);

        if (fuzzState.whitelistEnabled) {
            assertEq(ITokenizedStrategy(address(oldUsd3)).maxDeposit(INERT_PROBE), 0, "old whitelist gate active");
        }
        assertEq(ITokenizedStrategy(address(oldUsd3)).maxRedeem(ALICE), 0, "old commitment gate active");

        vm.prank(management);
        ITokenizedStrategy(address(oldUsd3)).setProfitMaxUnlockTime(fuzzState.profitMaxUnlockTime);
        waUSDC.setSharePrice(fuzzState.waUsdcSharePrice);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = ITokenizedStrategy(address(oldUsd3)).report();
        assertGt(profit, 0, "reported profit");
        assertEq(loss, 0, "no reported loss");

        vm.warp(block.timestamp + fuzzState.profitUnlockElapsed);
        assertGt(ITokenizedStrategy(address(oldUsd3)).unlockedShares(), 0, "profit partly unlocked");
        assertGt(ITokenizedStrategy(address(oldUsd3)).balanceOf(address(oldUsd3)), 0, "profit remains locked");

        Position memory position = oldUsd3.morphoCredit().position(oldUsd3.marketId(), address(oldUsd3));
        assertGt(position.supplyShares, 0, "active Morpho supply position");
        assertGt(oldUsd3.balanceOfWaUSDC(), 0, "local waUSDC holdings");
    }

    function _snapshotUsers(USD3_old oldUsd3, address[3] memory users)
        internal
        view
        returns (UserSnapshot memory snapshot)
    {
        ITokenizedStrategy tokenized = ITokenizedStrategy(address(oldUsd3));
        for (uint256 i; i < users.length; ++i) {
            snapshot.shareBalances[i] = tokenized.balanceOf(users[i]);
            snapshot.assetBalances[i] = asset.balanceOf(users[i]);
            snapshot.shareAllowances[i] = tokenized.allowance(users[i], SHARE_SPENDER);
            snapshot.assetAllowances[i] = asset.allowance(users[i], address(oldUsd3));
            snapshot.whitelistEntries[i] =
                vm.load(address(oldUsd3), keccak256(abi.encode(users[i], DEPRECATED_WHITELIST_SLOT)));
            snapshot.depositTimestampEntries[i] =
                vm.load(address(oldUsd3), keccak256(abi.encode(users[i], DEPRECATED_DEPOSIT_TIMESTAMP_SLOT)));
            assertNotEq(snapshot.depositTimestampEntries[i], bytes32(0), "populated deposit timestamp");
        }
    }

    function _snapshotStrategy(USD3_old oldUsd3) internal view returns (StrategySnapshot memory snapshot) {
        ITokenizedStrategy tokenized = ITokenizedStrategy(address(oldUsd3));
        IMorpho morpho = oldUsd3.morphoCredit();

        snapshot.totalSupply = tokenized.totalSupply();
        snapshot.totalAssets = tokenized.totalAssets();
        snapshot.pricePerShare = tokenized.pricePerShare();
        snapshot.nav = oldUsd3.nav();
        snapshot.localWaUsdc = oldUsd3.balanceOfWaUSDC();
        snapshot.suppliedWaUsdc = oldUsd3.suppliedWaUSDC();
        snapshot.morphoWaUsdcBalance = IERC20(address(waUSDC)).balanceOf(address(morpho));
        snapshot.waUsdcAllowance = IERC20(address(waUSDC)).allowance(address(oldUsd3), address(morpho));
        snapshot.assetAllowance = asset.allowance(address(oldUsd3), address(waUSDC));
        snapshot.profitMaxUnlockTime = tokenized.profitMaxUnlockTime();
        snapshot.fullProfitUnlockDate = tokenized.fullProfitUnlockDate();
        snapshot.profitUnlockingRate = tokenized.profitUnlockingRate();
        snapshot.lastReport = tokenized.lastReport();
        snapshot.unlockedShares = tokenized.unlockedShares();
        snapshot.morphoPosition = morpho.position(oldUsd3.marketId(), address(oldUsd3));
        snapshot.initializerWord = vm.load(address(oldUsd3), INITIALIZABLE_STORAGE_SLOT);
        snapshot.deprecatedWhitelistEnabledWord = vm.load(address(oldUsd3), bytes32(DEPRECATED_WHITELIST_ENABLED_SLOT));

        assertEq(snapshot.totalAssets, snapshot.nav, "report synchronized totalAssets and NAV");
        assertGt(snapshot.fullProfitUnlockDate, block.timestamp, "profit unlock pending");
        assertGt(snapshot.unlockedShares, 0, "unlocked profit snapshot");
        assertGt(tokenized.balanceOf(address(oldUsd3)), 0, "locked profit snapshot");
    }

    function _assertUsersPreserved(USD3 upgraded, address[3] memory users, UserSnapshot memory before_) internal view {
        ITokenizedStrategy tokenized = ITokenizedStrategy(address(upgraded));
        for (uint256 i; i < users.length; ++i) {
            assertEq(tokenized.balanceOf(users[i]), before_.shareBalances[i], "user share balance");
            assertEq(asset.balanceOf(users[i]), before_.assetBalances[i], "user asset balance");
            assertEq(tokenized.allowance(users[i], SHARE_SPENDER), before_.shareAllowances[i], "share allowance");
            assertEq(asset.allowance(users[i], address(upgraded)), before_.assetAllowances[i], "asset allowance");
        }
    }

    function _assertStrategyPreserved(USD3 upgraded, StrategySnapshot memory before_) internal view {
        ITokenizedStrategy tokenized = ITokenizedStrategy(address(upgraded));
        IMorpho morpho = upgraded.morphoCredit();
        Position memory positionAfter = morpho.position(upgraded.marketId(), address(upgraded));

        assertEq(tokenized.totalSupply(), before_.totalSupply, "totalSupply");
        assertEq(tokenized.totalAssets(), before_.totalAssets, "totalAssets");
        assertEq(tokenized.pricePerShare(), before_.pricePerShare, "PPS");
        assertEq(upgraded.nav(), before_.nav, "NAV");
        assertEq(upgraded.balanceOfWaUSDC(), before_.localWaUsdc, "local waUSDC");
        assertEq(upgraded.suppliedWaUSDC(), before_.suppliedWaUsdc, "supplied waUSDC");
        assertEq(IERC20(address(waUSDC)).balanceOf(address(morpho)), before_.morphoWaUsdcBalance, "Morpho waUSDC");
        assertEq(
            IERC20(address(waUSDC)).allowance(address(upgraded), address(morpho)),
            before_.waUsdcAllowance,
            "waUSDC allowance"
        );
        assertEq(asset.allowance(address(upgraded), address(waUSDC)), before_.assetAllowance, "asset allowance");
        assertEq(tokenized.profitMaxUnlockTime(), before_.profitMaxUnlockTime, "profitMaxUnlockTime");
        assertEq(tokenized.fullProfitUnlockDate(), before_.fullProfitUnlockDate, "fullProfitUnlockDate");
        assertEq(tokenized.profitUnlockingRate(), before_.profitUnlockingRate, "profitUnlockingRate");
        assertEq(tokenized.lastReport(), before_.lastReport, "lastReport");
        assertEq(tokenized.unlockedShares(), before_.unlockedShares, "unlockedShares");
        assertEq(positionAfter.supplyShares, before_.morphoPosition.supplyShares, "Morpho supply shares");
        assertEq(positionAfter.borrowShares, before_.morphoPosition.borrowShares, "Morpho borrow shares");
        assertEq(positionAfter.collateral, before_.morphoPosition.collateral, "Morpho collateral");
        assertEq(vm.load(address(upgraded), INITIALIZABLE_STORAGE_SLOT), before_.initializerWord, "initializer word");
    }

    function _assertDeprecatedStatePreservedAndInert(
        USD3 upgraded,
        address[3] memory users,
        UserSnapshot memory usersBefore,
        StrategySnapshot memory strategyBefore
    ) internal view {
        assertEq(
            vm.load(address(upgraded), bytes32(DEPRECATED_WHITELIST_ENABLED_SLOT)),
            strategyBefore.deprecatedWhitelistEnabledWord,
            "deprecated whitelistEnabled word"
        );

        for (uint256 i; i < users.length; ++i) {
            assertEq(
                vm.load(address(upgraded), keccak256(abi.encode(users[i], DEPRECATED_WHITELIST_SLOT))),
                usersBefore.whitelistEntries[i],
                "deprecated whitelist entry"
            );
            assertEq(
                vm.load(address(upgraded), keccak256(abi.encode(users[i], DEPRECATED_DEPOSIT_TIMESTAMP_SLOT))),
                usersBefore.depositTimestampEntries[i],
                "deprecated deposit timestamp"
            );
        }

        assertGt(ITokenizedStrategy(address(upgraded)).maxDeposit(INERT_PROBE), 0, "deprecated whitelist is inert");
        assertGt(ITokenizedStrategy(address(upgraded)).maxRedeem(ALICE), 0, "deprecated commitment is inert");
    }

    function _deployUpgradeTarget() internal returns (USD3_old oldUsd3, ProxyAdmin proxyAdmin, address owner) {
        USD3 current = USD3(address(strategy));
        MorphoCredit morpho = MorphoCredit(address(current.morphoCredit()));
        owner = makeAddr("FuzzProxyAdminOwner");
        (oldUsd3, proxyAdmin) = _deployFrozenUsd3Proxy(address(morpho), current.marketId(), owner);

        vm.prank(makeAddr("MorphoOwner"));
        morpho.setUsd3(address(oldUsd3));
    }

    function _users() internal pure returns (address[3] memory users) {
        users = [ALICE, BOB, CHARLIE];
    }

    function _random(bytes32 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }
}
