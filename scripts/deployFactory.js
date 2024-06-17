require('dotenv').config();
const {  ethers, upgrade } = require("hardhat");
// const { ethers, ContractFactory } = require("ethers");

const API_KEY = process.env.API_KEY;
const PRIV_KEY = process.env.PRIV_KEY;
const ADDRESS = process.env.ADDRESS;

const main = async () => {
    
    const registry = await ethers.getContractFactory("Registry");
    console.log("deploying registry");

    await registry.deployed();

    console.log("registry deployed at: ", registry.address);

    /* To deploy proxy
    const proxyContract = await upgrades.deployProxy(ContractName, [input params for initializer function], {
        constructorArgs: [], // check if needed 
        initializer: "init", // or any other name used for the initializer
    });

    */

    return;

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
