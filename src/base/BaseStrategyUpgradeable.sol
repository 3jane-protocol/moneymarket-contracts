// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// TokenizedStrategy interface used for internal view delegateCalls.
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

/**
 * @title BaseStrategyUpgradeable
 * @author Modified from yearn.finance BaseStrategy for upgradeability
 * @notice
 *  BaseStrategyUpgradeable is a fork of Yearn V3's BaseStrategy that works
 *  with upgradeable proxy patterns. The main change is replacing the immutable
 *  TokenizedStrategy variable with proper delegatecall patterns.
 *
 *  It maintains full compatibility with TokenizedStrategy singleton pattern
 *  while allowing the strategy to be deployed behind a proxy.
 */
abstract contract BaseStrategyUpgradeable is Initializable {
    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Used on TokenizedStrategy callback functions to make sure it is post
     * a delegateCall from this address to the TokenizedStrategy.
     */
    modifier onlySelf() {
        _onlySelf();
        _;
    }

    /**
     * @dev Use to assure that the call is coming from the strategies management.
     */
    modifier onlyManagement() {
        _requireManagement();
        _;
    }

    /**
     * @dev Use to assure that the call is coming from either the strategies
     * management or the keeper.
     */
    modifier onlyKeepers() {
        _requireKeeperOrManagement();
        _;
    }

    /**
     * @dev Use to assure that the call is coming from either the strategies
     * management or the emergency admin.
     */
    modifier onlyEmergencyAuthorized() {
        _requireEmergencyAuthorized();
        _;
    }

    /**
     * @dev Require that the msg.sender is this address.
     */
    function _onlySelf() internal view {
        require(msg.sender == address(this), "!self");
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev This is the address of the TokenizedStrategy implementation
     * contract that will be used by all strategies to handle the
     * accounting, logic, storage etc.
     *
     * Any external calls to the that don't hit one of the functions
     * defined in this base or the strategy will end up being forwarded
     * through the fallback function, which will delegateCall this address.
     *
     * This address should be the same for every strategy, never be adjusted
     * and always be checked before any integration with the Strategy.
     */
    address public constant tokenizedStrategyAddress = 0xD377919FA87120584B21279a491F82D5265A139c;

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Underlying asset the Strategy is earning yield on.
     * Stored here for cheap retrievals within the strategy.
     */
    address internal _asset;

    /**
     * @dev This variable is set to address(this) during initialization.
     *
     * This is used for all calls to TokenizedStrategy to ensure proper
     * context in the upgradeable pattern.
     */
    address internal _tokenizedStrategy;

    /**
     * @dev This variable is set to ITokenizedStrategy(address(this)) during initialization.
     *
     * This provides a convenient way to call TokenizedStrategy functions
     * using clean syntax like TokenizedStrategy.totalAssets()
     */
    ITokenizedStrategy internal TokenizedStrategy;

    /**
     * @dev Storage gap for future upgrades
     */
    uint256[47] private __gap;

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the BaseStrategy.
     *
     * @param __asset Address of the underlying asset.
     * @param _name Name the strategy will use.
     * @param _management Address to set as management.
     * @param _performanceFeeRecipient Address to receive performance fees.
     * @param _keeper Address allowed to call tend() and report().
     */
    function __BaseStrategy_init(
        address __asset,
        string memory _name,
        address _management,
        address _performanceFeeRecipient,
        address _keeper
    ) internal onlyInitializing {
        _asset = __asset;
        _tokenizedStrategy = address(this);
        TokenizedStrategy = ITokenizedStrategy(address(this));

        // Initialize the strategy's storage variables via delegatecall.
        _delegateCall(
            abi.encodeCall(
                ITokenizedStrategy.initialize, (__asset, _name, _management, _performanceFeeRecipient, _keeper)
            )
        );
    }

    /**
     * @notice Initialize the BaseStrategy with defaults.
     * @dev Uses msg.sender for all permissioned roles.
     *
     * @param __asset Address of the underlying asset.
     * @param _name Name the strategy will use.
     */
    function __BaseStrategy_init_unchained(address __asset, string memory _name) internal onlyInitializing {
        __BaseStrategy_init(__asset, _name, msg.sender, msg.sender, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL MODIFIER LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Require that the caller is the management address.
     */
    function _requireManagement() internal view {
        (bool success, bytes memory data) =
            _tokenizedStrategy.staticcall(abi.encodeWithSignature("requireManagement(address)", msg.sender));
        if (!success) {
            assembly {
                let dataSize := mload(data)
                revert(add(data, 0x20), dataSize)
            }
        }
    }

    /**
     * @dev Require that the caller is the keeper or management.
     */
    function _requireKeeperOrManagement() internal view {
        (bool success, bytes memory data) =
            _tokenizedStrategy.staticcall(abi.encodeWithSignature("requireKeeperOrManagement(address)", msg.sender));
        if (!success) {
            assembly {
                let dataSize := mload(data)
                revert(add(data, 0x20), dataSize)
            }
        }
    }

    /**
     * @dev Require that the caller is the emergency admin or management.
     */
    function _requireEmergencyAuthorized() internal view {
        (bool success, bytes memory data) =
            _tokenizedStrategy.staticcall(abi.encodeWithSignature("requireEmergencyAuthorized(address)", msg.sender));
        if (!success) {
            assembly {
                let dataSize := mload(data)
                revert(add(data, 0x20), dataSize)
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    TOKENIZEDSTRATEGY VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Helper to call TokenizedStrategy.totalAssets()
     */
    function _totalAssets() internal view returns (uint256) {
        (bool success, bytes memory data) = _tokenizedStrategy.staticcall(abi.encodeWithSignature("totalAssets()"));
        require(success, "totalAssets failed");
        return abi.decode(data, (uint256));
    }

    /**
     * @dev Helper to call TokenizedStrategy.isShutdown()
     */
    function _isShutdown() internal view returns (bool) {
        (bool success, bytes memory data) = _tokenizedStrategy.staticcall(abi.encodeWithSignature("isShutdown()"));
        require(success, "isShutdown failed");
        return abi.decode(data, (bool));
    }

    /**
     * @dev Helper to call TokenizedStrategy.previewMint()
     */
    function _previewMint(uint256 shares) internal view returns (uint256) {
        (bool success, bytes memory data) =
            _tokenizedStrategy.staticcall(abi.encodeWithSignature("previewMint(uint256)", shares));
        require(success, "previewMint failed");
        return abi.decode(data, (uint256));
    }

    /*//////////////////////////////////////////////////////////////
                            GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the underlying asset.
     */
    function asset() public view returns (ERC20) {
        return ERC20(_asset);
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal virtual;

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal virtual;

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport() internal virtual returns (uint256 _totalAssets);

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     */
    function _tend(uint256 _totalIdle) internal virtual {}

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     */
    function _tendTrigger() internal view virtual returns (bool) {
        return false;
    }

    /**
     * @notice Returns if tend() should be called by a keeper.
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     * @return . Calldata for the tend call.
     */
    function tendTrigger() external view virtual returns (bool, bytes memory) {
        return (
            // Return the status of the tend trigger.
            _tendTrigger(),
            // And the needed calldata either way.
            abi.encodeWithSelector(ITokenizedStrategy.tend.selector)
        );
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     */
    function availableDepositLimit(address /*_owner*/ ) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(address /*_owner*/ ) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(uint256 _amount) internal virtual {}

    /*//////////////////////////////////////////////////////////////
                        TokenizedStrategy HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Can deploy up to '_amount' of 'asset' in yield source.
     * @dev Callback for the TokenizedStrategy to call during a {deposit}
     * or {mint} to tell the strategy it can deploy funds.
     *
     * Since this can only be called after a {deposit} or {mint}
     * delegateCall to the TokenizedStrategy msg.sender == address(this).
     *
     * Unless a whitelist is implemented this will be entirely permissionless
     * and thus can be sandwiched or otherwise manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can
     * attempt to deposit in the yield source.
     */
    function deployFunds(uint256 _amount) external virtual onlySelf {
        _deployFunds(_amount);
    }

    /**
     * @notice Should attempt to free the '_amount' of 'asset'.
     * @dev Callback for the TokenizedStrategy to call during a withdraw
     * or redeem to free the needed funds to service the withdraw.
     *
     * This can only be called after a 'withdraw' or 'redeem' delegateCall
     * to the TokenizedStrategy so msg.sender == address(this).
     *
     * @param _amount The amount of 'asset' that the strategy should attempt to free up.
     */
    function freeFunds(uint256 _amount) external virtual onlySelf {
        _freeFunds(_amount);
    }

    /**
     * @notice Returns the accurate amount of all funds currently
     * held by the Strategy.
     * @dev Callback for the TokenizedStrategy to call during a report to
     * get an accurate accounting of assets the strategy controls.
     *
     * This can only be called after a report() delegateCall to the
     * TokenizedStrategy so msg.sender == address(this).
     *
     * @return . A trusted and accurate account for the total amount
     * of 'asset' the strategy currently holds including idle funds.
     */
    function harvestAndReport() external virtual onlySelf returns (uint256) {
        return _harvestAndReport();
    }

    /**
     * @notice Will call the internal '_tend' when a keeper tends the strategy.
     * @dev Callback for the TokenizedStrategy to initiate a _tend call in the strategy.
     *
     * This can only be called after a tend() delegateCall to the TokenizedStrategy
     * so msg.sender == address(this).
     *
     * We name the function `tendThis` so that `tend` calls are forwarded to
     * the TokenizedStrategy.
     *
     * @param _totalIdle The amount of current idle funds that can be
     * deployed during the tend
     */
    function tendThis(uint256 _totalIdle) external virtual onlySelf {
        _tend(_totalIdle);
    }

    /**
     * @notice Will call the internal '_emergencyWithdraw' function.
     * @dev Callback for the TokenizedStrategy during an emergency withdraw.
     *
     * This can only be called after a emergencyWithdraw() delegateCall to
     * the TokenizedStrategy so msg.sender == address(this).
     *
     * We name the function `shutdownWithdraw` so that `emergencyWithdraw`
     * calls are forwarded to the TokenizedStrategy.
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function shutdownWithdraw(uint256 _amount) external virtual onlySelf {
        _emergencyWithdraw(_amount);
    }

    /**
     * @dev Function used to delegate call the TokenizedStrategy with
     * certain `_calldata` and return any return values.
     *
     * This is used to setup the initial storage of the strategy, and
     * can be used by strategist to forward any other call to the
     * TokenizedStrategy implementation.
     *
     * @param _calldata The abi encoded calldata to use in delegatecall.
     * @return . The return value if the call was successful in bytes.
     */
    function _delegateCall(bytes memory _calldata) internal returns (bytes memory) {
        // Delegate call the tokenized strategy with provided calldata.
        (bool success, bytes memory result) = tokenizedStrategyAddress.delegatecall(_calldata);

        // If the call reverted. Return the error.
        if (!success) {
            assembly {
                let ptr := mload(0x40)
                let size := returndatasize()
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }

        // Return the result.
        return result;
    }

    /**
     * @dev Execute a function on the TokenizedStrategy and return any value.
     *
     * This fallback function will be executed when any of the standard functions
     * defined in the TokenizedStrategy are called since they wont be defined in
     * this contract.
     *
     * It will delegatecall the TokenizedStrategy implementation with the exact
     * calldata and return any relevant values.
     *
     */
    fallback() external {
        // load our target address
        address _tokenizedStrategyAddress = tokenizedStrategyAddress;
        // Execute external function using delegatecall and return any value.
        assembly {
            // Copy function selector and any arguments.
            calldatacopy(0, 0, calldatasize())
            // Execute function delegatecall.
            let result := delegatecall(gas(), _tokenizedStrategyAddress, 0, calldatasize(), 0, 0)
            // Get any return value
            returndatacopy(0, 0, returndatasize())
            // Return any return value or error back to the caller
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
