const { ethers } = require("hardhat");
const dotenv = require("dotenv");
const ADDRESS = require("../deployments/address.json");

dotenv.config();

async function main() {
    console.log("Starting DeviceWallet upgrade script...");

    const networkName = hre.network.name;
    console.log(`Running on network: ${networkName}`);

    // PRIVATE_KEY_1 -> Upgrade Manager
    if (!process.env.PRIVATE_KEY_1) {
        throw new Error(
            "PRIVATE_KEY_1 is not set in .env file"
        );
    }
    const upgradeManagerWallet = new ethers.Wallet(process.env.PRIVATE_KEY_1, ethers.provider);
    console.log(`Using upgrade manager account: ${upgradeManagerWallet.address}`);
    console.log(`Upgrade manager balance: ${ethers.formatEther(await ethers.provider.getBalance(upgradeManagerWallet.address))} ETH`);

    // Required addresses from your .env file (filled with your provided values)
    const entryPointAddress = process.env.ENTRY_POINT_ZERO_POINT_SEVEN_ADDRESS;
    const p256VerifierAddress = ADDRESS[network.config.name].P256Verifier;
    const deviceWalletFactoryAddress = ADDRESS[network.config.name].DeviceWalletFactoryProxy;

    console.log(`Using EntryPoint at: ${entryPointAddress}`);
    console.log(`Using P256Verifier at: ${p256VerifierAddress}`);
    console.log(`DeviceWalletFactory Proxy is at: ${deviceWalletFactoryAddress}`);

    // 1. Deploy the new DeviceWallet implementation (logic contract)
    console.log("Deploying new DeviceWallet implementation (logic contract)...");
    const DeviceWallet_New = await ethers.getContractFactory("DeviceWallet");
    
    // The constructor for DeviceWallet.sol takes entryPointAddress and p256VerifierAddress
    const newDeviceWalletImpl = await DeviceWallet_New.deploy(entryPointAddress, p256VerifierAddress);
    await newDeviceWalletImpl.waitForDeployment();
    const newDeviceWalletImplAddress = await newDeviceWalletImpl.getAddress();
    console.log(`New DeviceWallet implementation deployed to: ${newDeviceWalletImplAddress}`);

    // 2. Get the DeviceWalletFactory contract instance
    const DeviceWalletFactory = await ethers.getContractFactory("DeviceWalletFactory");
    const deviceWalletFactory = DeviceWalletFactory.attach(deviceWalletFactoryAddress);
    console.log(`Attached to DeviceWalletFactory proxy at: ${await deviceWalletFactory.getAddress()}`);

    // 3. Call the function on DeviceWalletFactory to upgrade the beacon
    const upgradeFunctionName = "updateDeviceWalletImplementation";

    console.log(`Current DeviceWallet implementation (before upgrade) reported by factory: ${await deviceWalletFactory.getCurrentDeviceWalletImplementation()}`);

    console.log(`Calling '${upgradeFunctionName}' on DeviceWalletFactory with new implementation: ${newDeviceWalletImplAddress}`);
    const tx = await deviceWalletFactory.connect(upgradeManagerWallet).updateDeviceWalletImplementation(newDeviceWalletImplAddress);
    console.log(`Upgrade transaction sent: ${tx.hash}`);
    const receipt = await tx.wait(); // Wait for the transaction to be mined
    console.log(`Upgrade transaction confirmed in block ${receipt.blockNumber}. Gas used: ${receipt.gasUsed.toString()}`);
    console.log("DeviceWallet implementation upgraded successfully in DeviceWalletFactory's beacon!");

    // 4. Verification
    // The factory has: getCurrentDeviceWalletImplementation() public view returns (address)
    const currentFactoryImpl = await deviceWalletFactory.getCurrentDeviceWalletImplementation();
    console.log(`Verified: Factory now reports DeviceWallet implementation: ${currentFactoryImpl}`);

    if (currentFactoryImpl.toLowerCase() !== newDeviceWalletImplAddress.toLowerCase()) {
        console.error("ERROR: Factory's reported implementation address does not match the new deployed implementation address!");
        console.error(`Expected: ${newDeviceWalletImplAddress}, Got: ${currentFactoryImpl}`);
    } else {
        console.log("Verification successful: Factory's reported implementation matches the new deployment.");
    }

    console.log("\n--- UPGRADE SUMMARY ---");
    console.log(`New DeviceWallet Implementation (logic contract): ${newDeviceWalletImplAddress}`);
    console.log(`DeviceWalletFactory Proxy: ${deviceWalletFactoryAddress}`);
    console.log(`Upgrade performed by (Owner/UpgradeManager): ${upgradeManagerWallet.address}`);
    console.log("All existing and future DeviceWallets deployed via this factory's beacon will now use the new implementation.");
    console.log("--- END SUMMARY ---\n");

    console.log("Upgrade script completed successfully!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Upgrade script failed:", error);
        process.exit(1);
    });
