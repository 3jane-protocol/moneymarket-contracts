#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const csvPath = process.argv[2];
if (!csvPath) {
  console.error('Usage: node csv-to-creditlines.js <csv-file>');
  process.exit(1);
}

const csv = fs.readFileSync(csvPath, 'utf8');
const lines = csv.trim().split('\n');

// Skip header
const dataLines = lines.slice(1);

const creditLines = dataLines.map(line => {
  const cols = line.split(',');
  // CSV columns: name, name, Address, vv, Capped Loan Amount, Effective Rate, Minus RFR, Per Second rate
  const address = cols[2].trim();
  const vv = cols[3].trim();
  const credit = cols[4].trim();
  const drp = cols[7].trim();

  // JSON keys must be alphabetically ordered to match struct field order:
  // borrower_address (1st) -> borrower, credit (2nd) -> credit, drp (3rd) -> drp, vv (4th) -> vv
  // Values must be JSON numbers (not strings) for parseJson + abi.decode to work
  return {
    borrower_address: address,
    credit: parseInt(credit),
    drp: parseInt(drp),
    vv: parseInt(vv)
  };
});

// Output JSON file next to CSV
const outputPath = csvPath.replace('.csv', '.json');
fs.writeFileSync(outputPath, JSON.stringify(creditLines, null, 2));
console.log(`Wrote ${creditLines.length} credit lines to ${outputPath}`);
console.log(JSON.stringify(creditLines, null, 2));
