// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

// Add imports for USD3 testing
import {USD3} from "../../USD3.sol";
import {IMorpho, MarketParams} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {MorphoCredit} from "@3jane-morpho-blue/MorphoCredit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ATokenVault} from "@Aave-Vault/src/ATokenVault.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is Test, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    ERC20 public underlyingAsset;
    IStrategyInterface public strategy;

    // StrategyFactory not used in this test setup

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    uint256 public maxFuzzAmount = 1_000_000_000e6;
    uint256 public minFuzzAmount = 0.01e6;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        _setTokenAddrs();

        // Set underlying asset (USDC)
        underlyingAsset = ERC20(tokenAddrs["USDC"]);

        // StrategyFactory not used in this test setup

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        // Set decimals after asset is set in setUpStrategy
        decimals = asset.decimals();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(address(underlyingAsset), "underlyingAsset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        // Deploy real MorphoCredit with proxy pattern
        MorphoCredit morphoImpl = new MorphoCredit();

        // Deploy proxy admin
        address morphoOwner = makeAddr("MorphoOwner");
        address proxyAdminOwner = makeAddr("ProxyAdminOwner");
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        
        // Transfer ownership to proxyAdminOwner
        proxyAdmin.transferOwnership(proxyAdminOwner);

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(MorphoCredit.initialize.selector, morphoOwner);
        TransparentUpgradeableProxy morphoProxy =
            new TransparentUpgradeableProxy(address(morphoImpl), address(proxyAdmin), initData);

        IMorpho morpho = IMorpho(address(morphoProxy));

        // Deploy MockATokenVault
        MockATokenVault aTokenVault = new MockATokenVault(IERC20(address(underlyingAsset)));

        // Set asset to aTokenVault for USD3 strategy
        asset = ERC20(address(aTokenVault));

        // Set up market params for credit-based lending
        MarketParams memory marketParams = MarketParams({
            loanToken: address(aTokenVault),
            collateralToken: address(underlyingAsset), // Use USDC as collateral token
            oracle: address(0), // Not needed for credit
            irm: address(0), // Mock IRM
            lltv: 0, // Credit-based lending
            creditLine: makeAddr("CreditLine")
        });

        // Enable market parameters
        vm.startPrank(morphoOwner);
        morpho.enableIrm(address(0));
        morpho.enableLltv(0);
        morpho.createMarket(marketParams);
        vm.stopPrank();

        // Deploy USD3 strategy
        USD3 _strategy = new USD3(address(aTokenVault), address(morpho), marketParams);

        // Transfer management from test contract to management address
        IStrategyInterface(address(_strategy)).setPendingManagement(management);
        vm.prank(management);
        IStrategyInterface(address(_strategy)).acceptManagement();

        // Set keeper and performance fee recipient
        vm.prank(management);
        IStrategyInterface(address(_strategy)).setKeeper(keeper);
        vm.prank(management);
        IStrategyInterface(address(_strategy)).setPerformanceFeeRecipient(performanceFeeRecipient);
        vm.prank(management);
        IStrategyInterface(address(_strategy)).setEmergencyAdmin(emergencyAdmin);

        return address(_strategy);
    }

    function depositIntoStrategy(IStrategyInterface _strategy, address _user, uint256 _amount) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(IStrategyInterface _strategy, address _user, uint256 _amount) public {
        // Since asset is now the aTokenVault and underlyingAsset is USDC,
        // we need to mint USDC and convert to aTokens

        // Mint USDC to user
        airdrop(underlyingAsset, _user, _amount);

        // Approve and deposit USDC to aTokenVault
        vm.prank(_user);
        underlyingAsset.approve(address(asset), _amount);

        vm.prank(_user);
        uint256 aTokenAmount = MockATokenVault(address(asset)).deposit(_amount, _user);

        // Approve and deposit aTokens to strategy
        vm.prank(_user);
        asset.approve(address(_strategy), aTokenAmount);

        vm.prank(_user);
        _strategy.deposit(aTokenAmount, _user);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        tokenAddrs["aUSDC"] = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
        tokenAddrs["AAVE_POOL_ADDRESSES_PROVIDER"] = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    }

    // USD3-specific setup function
    function setUpUSD3Strategy(address _morpho, MarketParams memory _marketParams) public returns (address) {
        // Deploy USD3 strategy
        USD3 _strategy = new USD3(
            _marketParams.loanToken, // Use loanToken from marketParams
            _morpho,
            _marketParams
        );

        // Set up management
        IStrategyInterface(address(_strategy)).setPendingManagement(management);
        vm.prank(management);
        IStrategyInterface(address(_strategy)).acceptManagement();

        // Set keeper and performance fee recipient
        vm.prank(management);
        IStrategyInterface(address(_strategy)).setKeeper(keeper);
        vm.prank(management);
        IStrategyInterface(address(_strategy)).setPerformanceFeeRecipient(performanceFeeRecipient);
        vm.prank(management);
        IStrategyInterface(address(_strategy)).setEmergencyAdmin(emergencyAdmin);

        return address(_strategy);
    }
}
