const { ethers, upgrades, hre, network } = require("hardhat");
const dotenv = require("dotenv");
const ADDRESS = require("../deployments/address.json");

dotenv.config();

async function main() {

    const provider = new ethers.JsonRpcProvider(network.config.url);
    // const provider = new ethers.AlchemyProvider(network.config.name, process.env.ALCHEMY_API_KEY);

    // Check for required environment variables
    const upgradeManagerAddress = process.env.UPGRADE_MANAGER;
    const eSIMWalletAdminAddress = process.env.ESIM_WALLET_ADMIN;
    const vaultAddress = process.env.VAULT;

    const upgradeManagerSigner = new ethers.Wallet(process.env.PRIVATE_KEY_1, provider);
    const eSIMWalletAdminSigner = new ethers.Wallet(process.env.PRIVATE_KEY_3, provider);

    const registryAddress = ADDRESS[network.config.name].RegistryProxy;
    const deviceWalletFactoryAddress = ADDRESS[network.config.name].DeviceWalletFactoryProxy;
    const eSIMWalletFactoryAddress = ADDRESS[network.config.name].ESIMWalletFactoryProxy;
    const lazyWalletRegistryAddress = ADDRESS[network.config.name].LazyWalletRegistryProxy;

    const registry = await ethers.getContractAt("Registry", registryAddress);
    const deviceWalletFactory = await ethers.getContractAt("DeviceWalletFactory", deviceWalletFactoryAddress);
    const eSIMWalletFactory = await ethers.getContractAt("ESIMWalletFactory", eSIMWalletFactoryAddress);

    // Post-deployment configuration
    console.log("--- START TASK ---\n");
    console.log("Performing post-deployment configuration...");

    // 1. Set LazyWalletRegistry address in Registry (as upgradeManager)
    console.log("Setting LazyWalletRegistry address in Registry...");
    const tx1 = await registry.connect(upgradeManagerSigner).addOrUpdateLazyWalletRegistryAddress(lazyWalletRegistryAddress);
    await tx1.wait();
    console.log("LazyWalletRegistry address set in Registry");

    // 2. Set Registry address in DeviceWalletFactory (as eSIMWalletAdmin)
    console.log("Setting Registry address in DeviceWalletFactory...");
    const tx2 = await deviceWalletFactory.connect(eSIMWalletAdminSigner).addRegistryAddress(registryAddress);
    await tx2.wait();
    console.log("Registry address set in DeviceWalletFactory");

    // 3. Set Registry address in ESIMWalletFactory (as upgradeManager)
    console.log("Setting Registry address in ESIMWalletFactory...");
    const tx3 = await eSIMWalletFactory.connect(upgradeManagerSigner).addRegistryAddress(registryAddress);
    await tx3.wait();
    console.log("Registry address set in ESIMWalletFactory");
    console.log("--- END TASK ---\n");
}

main()
.then(() => process.exit(0))
.catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
});

