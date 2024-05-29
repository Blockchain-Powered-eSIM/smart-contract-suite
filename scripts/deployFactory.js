require('dotenv').config();
const { ethers } = require("hardhat");
// const { ethers, ContractFactory } = require("ethers");

const API_KEY = process.env.API_KEY;
const PRIV_KEY = process.env.PRIV_KEY;
const ADDRESS = process.env.ADDRESS;

const main = async () => {

    const [deployer] = await ethers.getSigners();
    console.log("deployer: ", deployer);

    // const provider = new ethers.providers.AlchemyProvider(
    //     "sepolia",
    //     API_KEY
    // );
    // const signer = new ethers.Wallet(PRIV_KEY, provider);
    
    // const deviceWalletFactory = await ethers.getContractFactory
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
