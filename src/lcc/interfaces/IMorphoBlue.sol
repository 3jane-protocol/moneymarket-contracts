// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

/// @title IMorphoBlue
/// @notice Minimal interface of the canonical Morpho Blue singleton used by the LCC leveraged funding helper.
/// @dev This is the canonical Morpho Blue ABI, not the MorphoCredit fork in `src/interfaces/IMorpho.sol`, whose market
/// parameters and entrypoints are not ABI-compatible with the canonical singleton.
interface IMorphoBlue {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    struct Authorization {
        address authorizer;
        address authorized;
        bool isAuthorized;
        uint256 nonce;
        uint256 deadline;
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function supplyCollateral(MarketParams calldata marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external;

    function borrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    function flashLoan(address token, uint256 assets, bytes calldata data) external;

    function setAuthorizationWithSig(Authorization calldata authorization, Signature calldata signature) external;

    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);

    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}

/// @notice Callback Morpho Blue invokes on the `flashLoan` caller after transferring the loaned assets and before
/// pulling the same amount back without a fee.
interface IMorphoBlueFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

/// @notice Morpho Blue market oracle: price of one collateral unit in loan units, scaled by 1e36.
interface IMorphoBlueOracle {
    function price() external view returns (uint256);
}
