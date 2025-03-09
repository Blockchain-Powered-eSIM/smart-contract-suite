require('dotenv').config();
const hre = require("hardhat");
const { ethers } = require("@nomicfoundation/hardhat-ethers");
const P256VerifierModule = require("../ignition/modules/p256Verifier.js");
const DeviceWalletImplModule = require("../ignition/modules/deviceWallet.js");
const { deployContract } = require('@nomicfoundation/hardhat-ethers/types/index.js');
// const { ethers, ContractFactory } = require("ethers");

// import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
// import {P256Verifier} from "../contracts/P256Verifier.sol";
// import {ESIMWalletFactory} from "../contracts/esim-wallet/ESIMWalletFactory.sol";
// import {DeviceWalletFactory} from "../contracts/device-wallet/DeviceWalletFactory.sol";
// import {Registry} from "../contracts/Registry.sol";
// import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";
// import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";
// import {LazyWalletRegistry} from "contracts/LazyWalletRegistry.sol";

async function main () {
    // 1. Get EntryPoint contract
    // TODO: correctly attach IEntryPoint contract
    // const entryPointArtifact = await hre.artifacts.readArtifact("IEntryPoint");
    const entryPoint = await hre.viem.getContractAt("IEntryPoint", "0x0000000071727De22E5E9d8BAf0edAc6f37da032");
    // const entryPoint = await hre.ethers.getContractAt("IEntryPoint", "0x0000000071727De22E5E9d8BAf0edAc6f37da032");
    // const EntryPointContract = await hre.ethers.getContractFactory("EntryPoint");
    // mainnet. TODO: add sepolia address
    // const entryPointZeroPointSeven = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
    // const typecastEntryPoint = await EntryPointContract.attach(entryPointZeroPointSeven);
    // IEntryPoint typeCastEntryPoint = IEntryPoint(address(entryPointZeroPointSeven));
    // console.log("EntryPoint deployed at:", address(typeCastEntryPoint));

    // 2. Deploy P256 Verifier
    // const P256Verifier = await hre.ethers.getContractFactory("P256Verifier");
    // const p256Verifier = await P256Verifier.deploy();
    // console.log("P256Verifier address: ", await p256Verifier.getAddress());
    const p256Verifier = await hre.viem.deployContract("P256Verifier");
    console.log("P256Verifier address: ", p256Verifier.address);
    // const P256Verifier = await hre.ignition.deploy(P256VerifierModule);
    // const p256Verifier = await P256Verifier.p256Verifier.getAddress();
    // console.log("P256Verifier deployed at:", p256Verifier);

    const deviceWalletImpl = await hre.viem.deployContract(
        "DeviceWallet", [
            entryPoint.address,
            p256Verifier.address
        ]
    );
    console.log("Device wallet implementation address: ", deviceWalletImpl.address);

    const deviceWalletFactory = await hre.viem.deployContract(
        "DeviceWalletFactory", [
            deviceWalletImpl.address,
            process.env.ESIM_WALLET_ADMIN,
            process.env.VAULT,
            process.env.UPGRADE_MANAGER,
            entryPoint.address,
            p256Verifier.address
        ]
    );
    console.log("DeviceWalletFactory contract: ", deviceWalletFactory.address);

    // Deploy device wallet implementation
    // const DeviceWalletImpl = await ethers.getContractFactory('DeviceWallet');
    // console.log("Deploying device wallet implementation");
    // const deviceWalletimpl = await DeviceWalletImpl();
    // // const Box = await ethers.getContractFactory('Box');
    // console.log('Deploying Box...');
    // const box = await Box.deploy();
    // await box.waitForDeployment();
    // console.log('Box deployed to:', await box.getAddress());
}
  
main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
