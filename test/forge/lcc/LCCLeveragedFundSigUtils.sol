// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {IERC20Permit} from "../../../lib/openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {ILCCLeveragedFundHelper} from "../../../src/lcc/interfaces/ILCCLeveragedFundHelper.sol";
import {IMorphoBlue} from "../../../src/lcc/interfaces/IMorphoBlue.sol";
import {IMorphoBlueTest} from "./IMorphoBlueTest.sol";
import {AUTHORIZATION_TYPEHASH} from "../../../src/libraries/ConstantsLib.sol";

/// @dev EIP-2612 permit and canonical Morpho Blue authorization signing shared by the unit and fork suites.
abstract contract LCCLeveragedFundSigUtils is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    struct SignRequest {
        address helper;
        address morpho;
        address usdc;
        address usd3l;
        uint256 key;
        uint256 usdcValue;
        uint256 usd3lValue;
        uint256 deadline;
    }

    struct Signed {
        ILCCLeveragedFundHelper.PermitSignature usdcPermit;
        ILCCLeveragedFundHelper.PermitSignature usd3lPermit;
        ILCCLeveragedFundHelper.PermitSignature marginPermit;
        IMorphoBlue.Authorization authorization;
        IMorphoBlue.Signature signature;
    }

    function _signAll(SignRequest memory request) internal view returns (Signed memory signed) {
        signed.usdcPermit = _signPermit(request.usdc, request.key, request.helper, request.usdcValue, request.deadline);
        signed.usd3lPermit =
            _signPermit(request.usd3l, request.key, request.helper, request.usd3lValue, request.deadline);
        signed.authorization =
            _morphoAuthorization(request.morpho, vm.addr(request.key), request.helper, request.deadline);
        signed.signature = _signMorphoAuthorization(request.morpho, request.key, signed.authorization);
    }

    function _signPermit(address token, uint256 key, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (ILCCLeveragedFundHelper.PermitSignature memory permit)
    {
        address owner_ = vm.addr(key);
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner_, spender, value, IERC20Permit(token).nonces(owner_), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        permit = ILCCLeveragedFundHelper.PermitSignature({value: value, deadline: deadline, v: v, r: r, s: s});
    }

    function _submitPermit(
        address token,
        address owner_,
        address spender,
        ILCCLeveragedFundHelper.PermitSignature memory permit
    ) internal {
        IERC20Permit(token).permit(owner_, spender, permit.value, permit.deadline, permit.v, permit.r, permit.s);
    }

    function _morphoAuthorization(address morpho, address authorizer, address authorized, uint256 deadline)
        internal
        view
        returns (IMorphoBlue.Authorization memory)
    {
        return IMorphoBlue.Authorization({
            authorizer: authorizer,
            authorized: authorized,
            isAuthorized: true,
            nonce: IMorphoBlueTest(morpho).nonce(authorizer),
            deadline: deadline
        });
    }

    function _signMorphoAuthorization(address morpho, uint256 key, IMorphoBlue.Authorization memory authorization)
        internal
        view
        returns (IMorphoBlue.Signature memory signature)
    {
        bytes32 structHash = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IMorphoBlueTest(morpho).DOMAIN_SEPARATOR(), structHash));
        (signature.v, signature.r, signature.s) = vm.sign(key, digest);
    }
}
