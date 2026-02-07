import { readFileSync, writeFileSync } from "fs";

const contracts = ["OpenClawACLMHook", "OpenClawOracle"];

for (const name of contracts) {
  const artifact = JSON.parse(
    readFileSync(
      `packages/contracts/out/${name}.sol/${name}.json`,
      "utf-8"
    )
  );
  const abi = artifact.abi;
  writeFileSync(
    `packages/sdk/src/abis/${name}.ts`,
    `export const ${name}ABI = ${JSON.stringify(abi, null, 2)} as const;\n`
  );
  console.log(`Wrote ${name} ABI (${abi.length} entries)`);
}
