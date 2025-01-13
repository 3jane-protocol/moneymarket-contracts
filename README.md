# Morpho Blue IRMs

Some interest rate models for Morpho Blue:

- [AdaptiveCurveIRM](src/AdaptiveCurveIrm.sol)
  - _Important_: The `AdaptiveCurveIRM` was deployed [on Ethereum](https://etherscan.io/address/0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC) without the `via_ir` solc compilation option. 
    To check the bytecode on Ethereum, disable `via_ir` in `foundry.toml`. 
    Other deployments use `via_ir`.

## Resources

- AdaptiveCurveIRM: [documentation](https://www.notion.so/morpho-labs/Morpho-Blue-Documentation-Hub-External-00ff8194791045deb522821be46abbdc?pvs=4#d8269074bfd649009f28625a9caa38ea), [announcement article](https://morpho.mirror.xyz/aaUjIF85aIi5RT6-pLhVWBzuiCpOb4BV03OYNts2BHQ).

## Audits

All audits are stored in the [audits](audits)' folder.

## Getting started

Install dependencies: `yarn`

Run tests: `yarn test:forge`

## Licenses

The primary license is MIT, see [LICENSE](LICENSE).
