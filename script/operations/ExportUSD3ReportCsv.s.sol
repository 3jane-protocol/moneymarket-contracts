// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";

/// @title Export USD3 Report CSV
/// @notice Exports USD3 and sUSD3 report history with deployer non-deposit USDC contributions.
contract ExportUSD3ReportCsv is Script {
    function run() external {
        string[] memory cmd = new string[](2);
        cmd[0] = "node";
        cmd[1] = "script/utils/usd3-report-csv.js";

        string memory csv = string(vm.ffi(cmd));
        string memory outputPath = vm.envOr("USD3_REPORT_OUTPUT", string("data/usd3-report-events.csv"));

        vm.writeFile(outputPath, csv);

        console2.log("Wrote CSV to %s", outputPath);
        console2.log("");
        console2.log("%s", csv);
    }
}
