// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";

/// @title Export Borrower Borrow/Interest CSV
/// @notice Exports a borrower's MorphoCredit borrow, base interest, and premium accrual history.
contract ExportBorrowerBorrowInterestCsv is Script {
    function run() external {
        string[] memory cmd = new string[](2);
        cmd[0] = "node";
        cmd[1] = "script/utils/borrower-borrow-interest-csv.js";

        string memory csv = string(vm.ffi(cmd));
        string memory outputPath = vm.envOr(
            "BORROWER_BORROW_INTEREST_OUTPUT",
            string("data/morpho-credit-borrower-0x3ff3ff33d20a086834a095ed6ed562c9e189291b-borrows-interest.csv")
        );

        vm.writeFile(outputPath, csv);

        console2.log("Wrote CSV to %s", outputPath);
        console2.log("");
        console2.log("%s", csv);
    }
}
