require('dotenv').config();
require("@nomicfoundation/hardhat-ethers");
require('@openzeppelin/hardhat-upgrades');
require("@nomicfoundation/hardhat-foundry");
require('solidity-docgen');

const PRIV_KEY = process.env.PRIVATE_KEY_1;
const ALCHEMY_OP_SEPOLIA_HTTPS = process.env.ALCHEMY_OP_SEPOLIA_HTTPS;
const ALCHEMY_TENDERLY_OP_SEPOLIA_HTTPS = process.env.ALCHEMY_TENDERLY_OP_SEPOLIA_HTTPS;
const ALCHEMY_SEPOLIA_HTTPS = process.env.ALCHEMY_SEPOLIA_HTTPS;
const TENDERLY_KOKIO_MAINNET_FORK = process.env.TENDERLY_KOKIO_MAINNET_FORK;

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  defaultNetwork: "localhost",
  networks: {
    hardhat: {
      chainId: 31337,
    },
    sepolia: {
      name: "sepolia",
      chainId: 11155111,
      url: `${ALCHEMY_SEPOLIA_HTTPS}`,
      accounts: [PRIV_KEY],
      saveDeployments: true,
      ignition: {
        maxFeePerGasLimit: 50_000_000_000n, // 50 gwei
        maxPriorityFeePerGas: 2_000_000_000n, // 2 gwei
        gasPrice: 50_000_000_000n, // 50 gwei
        disableFeeBumping: false,
      },
    },
    op_sepolia: {
      name: "optimism-sepolia",
      chainId: 11155420,
      url: `${ALCHEMY_OP_SEPOLIA_HTTPS}`,
      accounts: [PRIV_KEY],
      saveDeployments: true,
      ignition: {
        maxFeePerGasLimit: 50_000_000_000n, // 50 gwei
        maxPriorityFeePerGas: 2_000_000_000n, // 2 gwei
        gasPrice: 50_000_000_000n, // 50 gwei
        disableFeeBumping: false,
      },
    },
    tenderly_op_sepolia: {
      name: "OP_Sepolia",
      chainId: 11155420,
      url: `${ALCHEMY_TENDERLY_OP_SEPOLIA_HTTPS}`,
      accounts: [PRIV_KEY],
      saveDeployments: true,
      ignition: {
        maxFeePerGasLimit: 50_000_000_000n, // 50 gwei
        maxPriorityFeePerGas: 2_000_000_000n, // 2 gwei
        gasPrice: 50_000_000_000n, // 50 gwei
        disableFeeBumping: false,
      },
    },
    kokio_mainnet_fork: {
      name: "kokio-mainnet-fork",
      chainId: 1122334455,
      url: `${TENDERLY_KOKIO_MAINNET_FORK}`,
      accounts: [PRIV_KEY],
      saveDeployments: true,
      ignition: {
        maxFeePerGasLimit: 50_000_000_000n, // 50 gwei
        maxPriorityFeePerGas: 2_000_000_000n, // 2 gwei
        gasPrice: 50_000_000_000n, // 50 gwei
        disableFeeBumping: false,
      },
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
    version: "0.8.25",
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
