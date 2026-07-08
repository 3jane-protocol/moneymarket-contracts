// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {IMorpho, Id, MarketParams} from "../../../../../src/interfaces/IMorpho.sol";
import {IProtocolConfig} from "../../../../../src/interfaces/IProtocolConfig.sol";
import {MAX_FEE} from "../../../../../src/libraries/ConstantsLib.sol";
import {ProtocolConfigLib} from "../../../../../src/libraries/ProtocolConfigLib.sol";

contract CoreGovernanceHandler is Test {
    bytes4 internal constant SET_FEE_SELECTOR =
        bytes4(keccak256("setFee((address,address,address,address,uint256,address),uint256)"));
    bytes4 internal constant SET_FEE_RECIPIENT_SELECTOR = bytes4(keccak256("setFeeRecipient(address)"));

    IMorpho public immutable morpho;
    IProtocolConfig public immutable protocolConfig;
    address public immutable owner;

    Id[] public marketIds;
    address[] public actors;

    uint256 public unauthorizedAttempts;
    uint256 public unauthorizedSuccesses;

    constructor(
        address _morpho,
        address _protocolConfig,
        address _owner,
        Id[] memory _marketIds,
        address[] memory _actors
    ) {
        require(_marketIds.length > 0, "no markets");
        require(_actors.length > 0, "no actors");

        morpho = IMorpho(_morpho);
        protocolConfig = IProtocolConfig(_protocolConfig);
        owner = _owner;

        for (uint256 i; i < _marketIds.length; ++i) {
            marketIds.push(_marketIds[i]);
        }
        for (uint256 i; i < _actors.length; ++i) {
            actors.push(_actors[i]);
        }
    }

    function setFee(uint256 marketSeed, uint256 feeSeed) external {
        MarketParams memory marketParams = morpho.idToMarketParams(marketIds[marketSeed % marketIds.length]);
        uint256 fee = bound(feeSeed, 0, MAX_FEE);
        if (fee == morpho.market(marketIds[marketSeed % marketIds.length]).fee) return;

        vm.prank(owner);
        morpho.setFee(marketParams, fee);
    }

    function setFeeRecipient(uint256 actorSeed) external {
        address recipient = actors[actorSeed % actors.length];
        if (recipient == morpho.feeRecipient()) return;

        vm.prank(owner);
        morpho.setFeeRecipient(recipient);
    }

    function setDebtCap(uint256 capSeed) external {
        uint256 cap = bound(capSeed, 1e18, 1e27);

        vm.prank(owner);
        protocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, cap);
    }

    function unauthorizedSetFeeAttempt(uint256 marketSeed, uint256 feeSeed) external {
        MarketParams memory marketParams = morpho.idToMarketParams(marketIds[marketSeed % marketIds.length]);
        uint256 fee = bound(feeSeed, 0, MAX_FEE);

        unauthorizedAttempts++;
        (bool ok,) = address(morpho).call(abi.encodeWithSelector(SET_FEE_SELECTOR, marketParams, fee));
        if (ok) unauthorizedSuccesses++;
    }

    function unauthorizedSetFeeRecipientAttempt(uint256 actorSeed) external {
        address recipient = actors[actorSeed % actors.length];

        unauthorizedAttempts++;
        (bool ok,) = address(morpho).call(abi.encodeWithSelector(SET_FEE_RECIPIENT_SELECTOR, recipient));
        if (ok) unauthorizedSuccesses++;
    }
}
