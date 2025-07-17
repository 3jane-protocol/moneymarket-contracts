// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC4626, ERC20, IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable} from "../../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title RealisticATokenVault
 * @notice A more realistic implementation of an Aave ATokenVault for testing
 * @dev Mimics the essential behavior of the real ATokenVault without requiring full Aave V3 setup
 */
contract RealisticATokenVault is ERC4626, Ownable {
    using Math for uint256;

    // State variables that mimic ATokenVault behavior
    uint256 public lastUpdate;
    uint256 public fee; // Fee in basis points (10000 = 100%)
    uint256 public constant YIELD_RATE = 3e16; // 3% APY base rate
    uint256 public constant FEE_PRECISION = 10000;
    
    // Simulate yield accrual over time
    uint256 private _accruedYield;
    uint256 private _totalDepositedAssets;
    
    // Fee recipient
    address public feeRecipient;
    
    event FeeUpdated(uint256 newFee);
    event FeeRecipientUpdated(address newFeeRecipient);

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _owner,
        uint256 _fee,
        address _feeRecipient
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable() {
        lastUpdate = block.timestamp;
        fee = _fee;
        feeRecipient = _feeRecipient;
        _transferOwnership(_owner);
    }

    /**
     * @dev Override decimals to handle assets without decimals function
     */
    function decimals() public view virtual override(ERC4626) returns (uint8) {
        (bool success, bytes memory result) = asset().staticcall(abi.encodeWithSignature("decimals()"));
        if (success && result.length >= 32) {
            return abi.decode(result, (uint8));
        }
        // Default to 6 decimals for USDC-like tokens if decimals() call fails
        return 6;
    }

    /**
     * @dev Override totalAssets to include accrued yield
     */
    function totalAssets() public view virtual override returns (uint256) {
        uint256 baseAssets = IERC20(asset()).balanceOf(address(this));
        uint256 accruedYield = _calculateAccruedYield(baseAssets);
        return baseAssets + accruedYield;
    }

    /**
     * @dev Calculate accrued yield based on time elapsed
     */
    function _calculateAccruedYield(uint256 baseAssets) internal view returns (uint256) {
        if (baseAssets == 0) return 0;
        
        uint256 timeElapsed = block.timestamp - lastUpdate;
        if (timeElapsed == 0) return _accruedYield;
        
        // Simple compound interest calculation
        // yield = baseAssets * rate * time / (365 days)
        uint256 newYield = baseAssets.mulDiv(YIELD_RATE * timeElapsed, 365 days * 1e18);
        return _accruedYield + newYield;
    }

    /**
     * @dev Update accrued yield and last update time
     */
    function _updateYield() internal {
        uint256 baseAssets = IERC20(asset()).balanceOf(address(this));
        _accruedYield = _calculateAccruedYield(baseAssets);
        lastUpdate = block.timestamp;
    }

    /**
     * @dev Override deposit to update yield
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        _updateYield();
        
        // Handle fee on yield before deposit
        _handleFeeOnYield();
        
        super._deposit(caller, receiver, assets, shares);
        _totalDepositedAssets += assets;
    }

    /**
     * @dev Override withdraw to update yield
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        _updateYield();
        
        // Handle fee on yield before withdrawal
        _handleFeeOnYield();
        
        super._withdraw(caller, receiver, owner, assets, shares);
        
        // Update total deposited assets proportionally
        if (totalSupply() > 0) {
            uint256 proportionalDecrease = _totalDepositedAssets.mulDiv(shares, totalSupply() + shares);
            _totalDepositedAssets = _totalDepositedAssets > proportionalDecrease ? 
                _totalDepositedAssets - proportionalDecrease : 0;
        }
    }

    /**
     * @dev Handle fee collection on yield
     */
    function _handleFeeOnYield() internal {
        if (_accruedYield > 0 && fee > 0 && feeRecipient != address(0)) {
            uint256 feeAmount = _accruedYield.mulDiv(fee, FEE_PRECISION);
            if (feeAmount > 0) {
                // Convert fee to shares and mint to fee recipient
                uint256 feeShares = convertToShares(feeAmount);
                if (feeShares > 0) {
                    _mint(feeRecipient, feeShares);
                }
                _accruedYield = _accruedYield > feeAmount ? _accruedYield - feeAmount : 0;
            }
        }
    }

    /**
     * @dev Set fee (only owner)
     */
    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= FEE_PRECISION, "Fee too high");
        _updateYield();
        _handleFeeOnYield();
        fee = _fee;
        emit FeeUpdated(_fee);
    }

    /**
     * @dev Set fee recipient (only owner)
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    /**
     * @dev Manual yield accrual for testing
     */
    function accrueYield() external {
        _updateYield();
        _handleFeeOnYield();
    }

    /**
     * @dev Get current yield that would be accrued
     */
    function getCurrentYield() external view returns (uint256) {
        uint256 baseAssets = IERC20(asset()).balanceOf(address(this));
        return _calculateAccruedYield(baseAssets);
    }

    /**
     * @dev Simulate additional yield for testing
     */
    function simulateYield(uint256 additionalYield) external {
        _updateYield();
        _accruedYield += additionalYield;
    }

    /**
     * @dev Get total deposited assets (excluding yield)
     */
    function totalDepositedAssets() external view returns (uint256) {
        return _totalDepositedAssets;
    }
}