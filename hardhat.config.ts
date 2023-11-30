import * as dotenv from "dotenv";

import { HardhatUserConfig, task } from "hardhat/config";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-waffle";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "solidity-coverage";
import 'hardhat-docgen';
import 'hardhat-contract-sizer';
import 'hardhat-abi-exporter';

dotenv.config();

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.17',
    settings: {
      optimizer: {
        runs: 200,
        enabled: true
      },
      outputSelection: {
        "*": {
          "*": ["storageLayout"]
        }
      }
    }
  },
  networks: {
    bscTestnet: {
      url: process.env.BSC_TESTNET_URL || "",
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    bscMainnet: {
      url: process.env.BSC_MAINNET_URL || "",
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    /**    hardhat: {
          forking: {
            url: process.env.BSC_GETBLOCK_URL || '',
          }
        }*/
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
  },
  mocha: {
    timeout: 700000
  },
  docgen: {
    path: './docs',
    clear: true,
    runOnCompile: true,
  },
  abiExporter: [
    {
      path: './abi/json',
      format: "json",
    }
  ]
  /**etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },*/
};

export default config;
