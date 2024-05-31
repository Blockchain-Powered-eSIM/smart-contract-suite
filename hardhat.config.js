require('dotenv').config();
require("@nomicfoundation/hardhat-foundry");
require('solidity-docgen');

const PRIV_KEY = process.env.PRIV_KEY;
const ALCHEMY_SEPOLIA_HTTPS = process.env.ALCHEMY_SEPOLIA_HTTPS;

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  defaultNetwork: "sepolia",
  networks: {
    hardhat: {
      chainId: 31337,
    },
    sepolia: {
      chainId: 11155111,
      url: `${ALCHEMY_SEPOLIA_HTTPS}`,
      accounts: [PRIV_KEY],
      saveDeployments: true
    },
    localhost: {
      url: "http://127.0.0.1:8545"
    }
  },
  namedAccounts: {
    deployer: {
        default: 0
    },
  },
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  },
  mocha: {
    timeout: 40000
  },
  docgen: {
    root: process.cwd(),
    sourcesDir: 'contracts',
    outputDir: 'docs',
    pages: 'files',
    exclude: [],
    theme: 'markdown',
    collapseNewlines: true,
    pageExtension: '.md',
  }
};
