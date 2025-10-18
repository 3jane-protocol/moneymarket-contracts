// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {MarketParams, Id} from "../../../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {ErrorsLib} from "../../../../src/libraries/ErrorsLib.sol";
import {ERC20Mock} from "../../../../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../../../../src/mocks/OracleMock.sol";
import {ConfigurableIrmMock} from "../../mocks/ConfigurableIrmMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title MarketCreationDOSTest
 * @notice Regression test for the Market Creation DOS vulnerability
 * @dev Tests the vulnerability where anyone can permanently block market creation by calling
 *      accruePremiumsForBorrowers or accrueBorrowerPremium with a non-existent market ID.
 *
 * Vulnerability Details:
 * - accruePremiumsForBorrowers() and accrueBorrowerPremium() are external with no auth
 * - They call _accrueInterest() which sets market[id].lastUpdate = block.timestamp
 * - This marks the ID as "used" even though the market was never created
 * - createMarket() checks if market[id].lastUpdate != 0 and reverts if true
 * - Result: Attacker can frontrun any createMarket call and permanently block it
 *
 * Attack Vector:
 * 1. Admin announces new market with specific parameters
 * 2. Attacker calculates the market ID from parameters
 * 3. Attacker frontruns admin's createMarket tx
 * 4. Attacker calls accruePremiumsForBorrowers(id, []) with empty array
 * 5. This sets market[id].lastUpdate without creating the market
 * 6. Admin's createMarket now reverts with MarketAlreadyCreated
 * 7. Market can never be created with those parameters
 */
contract MarketCreationDOSTest is Test {
    using MarketParamsLib for MarketParams;

    MorphoCredit public morpho;
    MockProtocolConfig public protocolConfig;
    CreditLineMock public creditLine;

    ERC20Mock public loanToken;
    ERC20Mock public collateralToken;
    OracleMock public oracle;
    ConfigurableIrmMock public irm;

    MarketParams public marketParams;
    Id public marketId;

    address public owner = makeAddr("owner");
    address public attacker = makeAddr("attacker");

    uint256 public constant ORACLE_PRICE = 1e18;

    function setUp() public {
        // Deploy protocol config
        protocolConfig = new MockProtocolConfig();

        // Deploy MorphoCredit implementation
        MorphoCredit morphoImpl = new MorphoCredit(address(protocolConfig));

        // Deploy proxy admin
        ProxyAdmin proxyAdmin = new ProxyAdmin(owner);

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(MorphoCredit.initialize.selector, owner);
        TransparentUpgradeableProxy morphoProxy =
            new TransparentUpgradeableProxy(address(morphoImpl), address(proxyAdmin), initData);

        morpho = MorphoCredit(address(morphoProxy));

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Setup tokens
        loanToken = new ERC20Mock();
        collateralToken = new ERC20Mock();
        oracle = new OracleMock();
        irm = new ConfigurableIrmMock();

        // Set oracle price
        oracle.setPrice(ORACLE_PRICE);

        // Create market params
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.8e18,
            creditLine: address(creditLine)
        });

        // Calculate market ID
        marketId = marketParams.id();

        // Enable IRM
        vm.prank(owner);
        morpho.enableIrm(address(irm));

        // Enable LLTV
        vm.prank(owner);
        morpho.enableLltv(0.8e18);
    }

    /**
     * @notice Test that demonstrates the DOS vulnerability (DISABLED - vulnerability is fixed)
     * @dev This test would show how attacker could frontrun createMarket and permanently block it
     * @dev Now disabled because the fix prevents this attack - see test_fix_prevents_dos tests instead
     */
    /*
    function test_dos_vulnerability_accruePremiumsForBorrowers() public {
        // Attacker frontruns admin with empty borrowers array
        vm.prank(attacker);
        morpho.accruePremiumsForBorrowers(marketId, new address[](0));

        // Admin now tries to create the market
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.MarketAlreadyCreated.selector);
        morpho.createMarket(marketParams);

        // Verify market is not actually created
        (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv, address creditLine) = morpho.idToMarketParams(marketId);
        assertEq(loanToken, address(0), "loanToken should be zero");
        assertEq(collateralToken, address(0), "collateralToken should be zero");
        assertEq(oracle, address(0), "oracle should be zero");
        assertEq(irm, address(0), "irm should be zero");
        assertEq(lltv, 0, "lltv should be zero");
        assertEq(creditLine, address(0), "creditLine should be zero");
    }
    */

    /**
     * @notice Test that demonstrates the DOS vulnerability with single borrower function (DISABLED - vulnerability is
     * fixed)
     * @dev This test would show the same attack works with accrueBorrowerPremium
     * @dev Now disabled because the fix prevents this attack - see test_fix_prevents_dos tests instead
     */
    /*
    function test_dos_vulnerability_accrueBorrowerPremium() public {
        address fakeBorrower = makeAddr("fakeBorrower");

        // Attacker frontruns admin with single borrower
        vm.prank(attacker);
        morpho.accrueBorrowerPremium(marketId, fakeBorrower);

        // Admin now tries to create the market
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.MarketAlreadyCreated.selector);
        morpho.createMarket(marketParams);

        // Verify market is not actually created
        (address loanToken_, address collateralToken_, address oracle_, address irm_, uint256 lltv_, address creditLine_) = morpho.idToMarketParams(marketId);
        assertEq(loanToken_, address(0), "loanToken should be zero");
        assertEq(collateralToken_, address(0), "collateralToken should be zero");
        assertEq(oracle_, address(0), "oracle should be zero");
        assertEq(irm_, address(0), "irm should be zero");
        assertEq(lltv_, 0, "lltv should be zero");
        assertEq(creditLine_, address(0), "creditLine should be zero");
    }
    */

    /**
     * @notice Test that the fix prevents the DOS attack
     * @dev After fix, both functions should revert with MarketNotCreated
     */
    function test_fix_prevents_dos_accruePremiumsForBorrowers() public {
        // Attacker tries to DOS but now it reverts
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        morpho.accruePremiumsForBorrowers(marketId, new address[](0));

        // Admin can now successfully create the market
        vm.prank(owner);
        morpho.createMarket(marketParams);

        // Verify market was created successfully
        (
            address loanToken_,
            address collateralToken_,
            address oracle_,
            address irm_,
            uint256 lltv_,
            address creditLine_
        ) = morpho.idToMarketParams(marketId);
        assertEq(loanToken_, address(loanToken), "loanToken mismatch");
        assertEq(collateralToken_, address(collateralToken), "collateralToken mismatch");
        assertEq(oracle_, address(oracle), "oracle mismatch");
        assertEq(irm_, address(irm), "irm mismatch");
        assertEq(lltv_, 0.8e18, "lltv mismatch");
        assertEq(creditLine_, address(creditLine), "creditLine mismatch");
    }

    /**
     * @notice Test that the fix prevents the DOS attack via single borrower function
     */
    function test_fix_prevents_dos_accrueBorrowerPremium() public {
        address fakeBorrower = makeAddr("fakeBorrower");

        // Attacker tries to DOS but now it reverts
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        morpho.accrueBorrowerPremium(marketId, fakeBorrower);

        // Admin can now successfully create the market
        vm.prank(owner);
        morpho.createMarket(marketParams);

        // Verify market was created successfully
        (
            address loanToken_,
            address collateralToken_,
            address oracle_,
            address irm_,
            uint256 lltv_,
            address creditLine_
        ) = morpho.idToMarketParams(marketId);
        assertEq(loanToken_, address(loanToken), "loanToken mismatch");
    }

    /**
     * @notice Test that legitimate usage still works after fix
     * @dev Verify functions work correctly for existing markets
     */
    function test_legitimate_usage_after_fix() public {
        // Admin creates the market first
        vm.prank(owner);
        morpho.createMarket(marketParams);

        address borrower = makeAddr("borrower");

        // Setup borrower with credit line
        vm.prank(address(creditLine));
        morpho.setCreditLine(marketId, borrower, 1000e18, 0);

        // Legitimate call to accruePremiumsForBorrowers should work
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        morpho.accruePremiumsForBorrowers(marketId, borrowers);

        // Legitimate call to accrueBorrowerPremium should work
        morpho.accrueBorrowerPremium(marketId, borrower);
    }

    /**
     * @notice Test multiple frontrun attempts
     * @dev Attacker tries multiple times but each fails after fix
     */
    function test_multiple_frontrun_attempts_blocked() public {
        // Attacker tries multiple times
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(attacker);
            vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
            morpho.accruePremiumsForBorrowers(marketId, new address[](0));
        }

        // Admin can still create the market
        vm.prank(owner);
        morpho.createMarket(marketParams);

        // Verify market exists
        (
            address loanToken_,
            address collateralToken_,
            address oracle_,
            address irm_,
            uint256 lltv_,
            address creditLine_
        ) = morpho.idToMarketParams(marketId);
        assertEq(loanToken_, address(loanToken), "Market should exist");
    }

    /**
     * @notice Test that empty array still reverts for non-existent market
     */
    function test_empty_array_reverts_for_non_existent_market() public {
        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        morpho.accruePremiumsForBorrowers(marketId, new address[](0));
    }

    /**
     * @notice Test that multiple borrowers array still reverts for non-existent market
     */
    function test_multiple_borrowers_revert_for_non_existent_market() public {
        address[] memory borrowers = new address[](3);
        borrowers[0] = makeAddr("borrower1");
        borrowers[1] = makeAddr("borrower2");
        borrowers[2] = makeAddr("borrower3");

        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        morpho.accruePremiumsForBorrowers(marketId, borrowers);
    }

    /**
     * @notice Test attack cost estimate
     * @dev Demonstrates the attack is extremely cheap
     */
    function test_attack_cost_is_minimal() public {
        uint256 gasBefore = gasleft();

        vm.prank(attacker);
        try morpho.accruePremiumsForBorrowers(marketId, new address[](0)) {
        // Attack succeeds (pre-fix)
        }
            catch {
            // Attack blocked (post-fix)
        }

        uint256 gasUsed = gasBefore - gasleft();

        // Attack costs very little gas (under 100k typically)
        // This makes it economically viable for persistent DOS
        emit log_named_uint("Gas used for DOS attempt", gasUsed);
        assertLt(gasUsed, 100000, "DOS attack should be cheap");
    }
}
