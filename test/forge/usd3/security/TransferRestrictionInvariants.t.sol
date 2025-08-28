// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TransparentUpgradeableProxy} from
    "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Math} from "../../../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title TransferRestrictionInvariants
 * @notice Invariant testing for transfer restriction functionality
 * @dev Uses stateful property testing to ensure invariants hold across all operations
 */
contract TransferRestrictionInvariants is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    TransferRestrictionHandler public handler;

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3 implementation with proxy
        sUSD3 susd3Implementation = new sUSD3();

        // Deploy proxy admin
        address proxyAdminOwner = makeAddr("ProxyAdminOwner");
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(proxyAdminOwner);

        // Deploy proxy with initialization
        bytes memory susd3InitData =
            abi.encodeWithSelector(sUSD3.initialize.selector, address(usd3Strategy), management, keeper);

        TransparentUpgradeableProxy susd3Proxy =
            new TransparentUpgradeableProxy(address(susd3Implementation), address(susd3ProxyAdmin), susd3InitData);

        susd3Strategy = sUSD3(address(susd3Proxy));

        // Link strategies
        // Set commitment period via protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress).protocolConfig();
        bytes32 USD3_COMMITMENT_TIME = keccak256("USD3_COMMITMENT_TIME");

        // Configure commitment and lock periods
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Set config as the owner (test contract in this case)
        MockProtocolConfig(protocolConfigAddress).setConfig(USD3_COMMITMENT_TIME, 7 days);

        vm.prank(management);
        usd3Strategy.setMinDeposit(100e6);

        // Deploy handler for invariant testing
        handler = new TransferRestrictionHandler(address(usd3Strategy), address(susd3Strategy), address(asset));

        // Fund handler with USDC
        airdrop(asset, address(handler), 1000000e6);

        // Set handler as target for invariant testing
        targetContract(address(handler));
    }

    // Core Invariants

    function invariant_commitment_period_consistency() public {
        // If a user has a deposit timestamp, they either:
        // 1. Have USD3 balance and are in or past commitment, or
        // 2. Have no balance (fully withdrawn)

        address[] memory users = handler.getUsers();
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 balance = IERC20(address(usd3Strategy)).balanceOf(user);
            uint256 depositTime = usd3Strategy.depositTimestamp(user);

            if (balance > 0 && depositTime > 0) {
                // User has balance and deposit timestamp
                // They should not be able to transfer if still in commitment
                if (block.timestamp < depositTime + 7 days) {
                    // Try to transfer (should fail)
                    vm.prank(user);
                    try IERC20(address(usd3Strategy)).transfer(address(1), 1) {
                        // Transfer succeeded when it shouldn't have
                        assertTrue(false, "Transfer succeeded during commitment");
                    } catch {
                        // Expected behavior
                    }
                }
            } else if (balance == 0 && depositTime > 0) {
                // This is acceptable - user withdrew everything
                // But timestamp should ideally be cleared
                // This is a design choice, not a hard invariant
            }
        }
    }

    function invariant_lock_period_enforcement() public {
        // If a user has sUSD3 balance and lockedUntil > block.timestamp,
        // they cannot transfer

        address[] memory users = handler.getUsers();
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 balance = IERC20(address(susd3Strategy)).balanceOf(user);
            uint256 lockedUntil = susd3Strategy.lockedUntil(user);

            if (balance > 0 && lockedUntil > block.timestamp) {
                // User is locked, should not be able to transfer
                vm.prank(user);
                try IERC20(address(susd3Strategy)).transfer(address(1), 1) {
                    assertTrue(false, "Transfer succeeded during lock period");
                } catch {
                    // Expected behavior
                }
            }
        }
    }

    function invariant_cooldown_shares_consistency() public {
        // Cooldown shares should never exceed user's balance

        address[] memory users = handler.getUsers();
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 balance = IERC20(address(susd3Strategy)).balanceOf(user);
            (,, uint256 cooldownShares) = susd3Strategy.getCooldownStatus(user);

            assertLe(cooldownShares, balance, "Cooldown shares exceed balance");
        }
    }

    function invariant_total_supply_conservation() public {
        // Total supply should equal sum of all balances

        uint256 totalSupply = IERC20(address(usd3Strategy)).totalSupply();
        address[] memory users = handler.getUsers();
        uint256 sumBalances = 0;

        for (uint256 i = 0; i < users.length; i++) {
            sumBalances += IERC20(address(usd3Strategy)).balanceOf(users[i]);
        }

        // Add sUSD3's balance (it holds USD3)
        sumBalances += IERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy));

        assertEq(totalSupply, sumBalances, "Total supply doesn't match sum of balances");
    }

    function invariant_subordination_ratio_maintained() public {
        // sUSD3's USD3 holdings should never exceed 15% of total USD3 supply

        uint256 usd3TotalSupply = IERC20(address(usd3Strategy)).totalSupply();
        uint256 susd3Holdings = IERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy));

        if (usd3TotalSupply > 0) {
            uint256 ratio = (susd3Holdings * 10000) / usd3TotalSupply;
            assertLe(ratio, 1500, "Subordination ratio exceeded 15%");
        }
    }

    function invariant_no_shares_lost() public {
        // No shares should be "lost" - all shares should be accounted for

        uint256 totalShares = IERC20(address(usd3Strategy)).totalSupply();
        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy)).totalAssets();

        // Total shares should correspond to total assets
        // (within reasonable rounding tolerance)
        if (totalShares > 0 && totalAssets > 0) {
            uint256 pricePerShare = (totalAssets * 1e18) / totalShares;

            // Price per share should be close to 1e18 (1:1) initially
            // Allow for some appreciation but not extreme values
            assertGt(pricePerShare, 0.9e18, "Price per share too low");
            assertLt(pricePerShare, 2e18, "Price per share suspiciously high");
        }
    }

    function invariant_transfer_restrictions_hold() public {
        // This is a meta-invariant that checks our restriction logic
        // Users in commitment/lock/cooldown should have appropriate restrictions

        address[] memory users = handler.getUsers();
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];

            // Check USD3 restrictions
            uint256 usd3Balance = IERC20(address(usd3Strategy)).balanceOf(user);
            uint256 depositTime = usd3Strategy.depositTimestamp(user);

            if (usd3Balance > 0 && depositTime > 0) {
                bool inCommitment = block.timestamp < depositTime + 7 days;

                if (inCommitment) {
                    // Should not be able to transfer to regular addresses
                    vm.prank(user);
                    try IERC20(address(usd3Strategy)).transfer(address(0x123), 1) {
                        assertTrue(false, "USD3 transfer during commitment should fail");
                    } catch {
                        // Expected
                    }

                    // But should be able to transfer to sUSD3
                    vm.prank(user);
                    try IERC20(address(usd3Strategy)).transfer(address(susd3Strategy), 0) {
                        // Zero transfer to sUSD3 should work
                    } catch {
                        assertTrue(false, "USD3 transfer to sUSD3 should work during commitment");
                    }
                }
            }

            // Check sUSD3 restrictions
            uint256 susd3Balance = IERC20(address(susd3Strategy)).balanceOf(user);
            uint256 lockedUntil = susd3Strategy.lockedUntil(user);

            if (susd3Balance > 0 && lockedUntil > block.timestamp) {
                // Should not be able to transfer during lock
                vm.prank(user);
                try IERC20(address(susd3Strategy)).transfer(address(0x123), 1) {
                    assertTrue(false, "sUSD3 transfer during lock should fail");
                } catch {
                    // Expected
                }
            }
        }
    }
}

/**
 * @title TransferRestrictionHandler
 * @notice Handler contract for invariant testing
 * @dev Performs random valid operations to test invariants
 */
contract TransferRestrictionHandler is Test {
    USD3 public immutable usd3;
    sUSD3 public immutable susd3;
    IERC20 public immutable usdc;

    address[] public users;
    mapping(address => bool) public isUser;

    uint256 public depositCount;
    uint256 public withdrawCount;
    uint256 public transferCount;
    uint256 public timeSkips;

    modifier useRandomUser(uint256 seed) {
        if (users.length == 0) {
            // Create first user
            address newUser = address(uint160(uint256(keccak256(abi.encode(seed, "user")))));
            users.push(newUser);
            isUser[newUser] = true;

            // Fund user
            deal(address(usdc), newUser, 10000e6);
        }

        // Select random user
        address user = users[seed % users.length];
        vm.startPrank(user);
        _;
        vm.stopPrank();
    }

    constructor(address _usd3, address _susd3, address _usdc) {
        usd3 = USD3(_usd3);
        susd3 = sUSD3(_susd3);
        usdc = IERC20(_usdc);
    }

    function deposit(uint256 seed, uint256 amount) public useRandomUser(seed) {
        amount = bound(amount, 100e6, 10000e6); // Reasonable deposit range

        uint256 userBalance = usdc.balanceOf(users[seed % users.length]);
        if (userBalance < amount) {
            // Fund user if needed
            deal(address(usdc), users[seed % users.length], amount);
        }

        usdc.approve(address(usd3), amount);
        try usd3.deposit(amount, users[seed % users.length]) {
            depositCount++;
        } catch {
            // Deposit might fail due to various reasons (whitelist, etc.)
        }
    }

    function withdraw(uint256 seed, uint256 amount) public useRandomUser(seed) {
        address user = users[seed % users.length];
        uint256 balance = IERC20(address(usd3)).balanceOf(user);

        if (balance > 0) {
            amount = bound(amount, 1, balance);

            try usd3.withdraw(amount, user, user) {
                withdrawCount++;
            } catch {
                // Withdraw might fail due to commitment period
            }
        }
    }

    function transfer(uint256 seed, uint256 amount, uint256 recipientSeed) public useRandomUser(seed) {
        address sender = users[seed % users.length];

        // Ensure we have at least 2 users
        if (users.length < 2) {
            address newUser = address(uint160(uint256(keccak256(abi.encode(recipientSeed, "recipient")))));
            if (!isUser[newUser]) {
                users.push(newUser);
                isUser[newUser] = true;
            }
        }

        address recipient = users[recipientSeed % users.length];
        if (recipient == sender && users.length > 1) {
            recipient = users[(recipientSeed + 1) % users.length];
        }

        uint256 balance = IERC20(address(usd3)).balanceOf(sender);
        if (balance > 0) {
            amount = bound(amount, 0, balance);

            try IERC20(address(usd3)).transfer(recipient, amount) {
                transferCount++;
            } catch {
                // Transfer might fail due to commitment period
            }
        }
    }

    function depositSUSD3(uint256 seed, uint256 amount) public useRandomUser(seed) {
        address user = users[seed % users.length];
        uint256 usd3Balance = IERC20(address(usd3)).balanceOf(user);

        if (usd3Balance > 0) {
            // Check available deposit limit for subordination
            uint256 limit = susd3.availableDepositLimit(user);
            amount = bound(amount, 0, Math.min(usd3Balance, limit));

            if (amount > 0) {
                IERC20(address(usd3)).approve(address(susd3), amount);
                try susd3.deposit(amount, user) {
                    // Success
                } catch {
                    // Might fail due to subordination ratio
                }
            }
        }
    }

    function startCooldown(uint256 seed, uint256 amount) public useRandomUser(seed) {
        address user = users[seed % users.length];
        uint256 balance = IERC20(address(susd3)).balanceOf(user);

        if (balance > 0) {
            amount = bound(amount, 1, balance);

            try susd3.startCooldown(amount) {
                // Success
            } catch {
                // Might fail if still in lock period
            }
        }
    }

    function skipTime(uint256 seed) public {
        uint256 timeToSkip = bound(seed, 1 hours, 30 days);
        skip(timeToSkip);
        timeSkips++;
    }

    function addUser(uint256 seed) public {
        address newUser = address(uint160(uint256(keccak256(abi.encode(seed, block.timestamp, "newUser")))));

        if (!isUser[newUser]) {
            users.push(newUser);
            isUser[newUser] = true;

            // Fund new user
            deal(address(usdc), newUser, 10000e6);
        }
    }

    function getUsers() public view returns (address[] memory) {
        return users;
    }
}
