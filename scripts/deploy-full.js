const { ethers, upgrades, hre } = require("hardhat");
const dotenv = require("dotenv");

dotenv.config();

async function main() {
    console.log("Starting deployment script...");

    // Get deployer account
    const [deployer] = await ethers.getSigners();
    console.log(`Deploying contracts with account: ${deployer.address}`);
    console.log(`Account balance: ${ethers.formatEther(await deployer.provider.getBalance(deployer.address))} ETH`);

    const provider = new ethers.JsonRpcProvider('http://localhost:8545');

    // Check for required environment variables
    const upgradeManagerAddress = process.env.UPGRADE_MANAGER;
    const upgradeManagerSigner = new ethers.Wallet(process.env.PRIVATE_KEY_1, provider);

    const eSIMWalletAdminAddress = process.env.ESIM_WALLET_ADMIN;
    const eSIMWalletAdminSigner = new ethers.Wallet(process.env.PRIVATE_KEY_3, provider);

    const vaultAddress = process.env.VAULT;

    await network.provider.send("hardhat_setBalance", [
        eSIMWalletAdminAddress,
        "0x1000000000000000000000000", // we are giving ourselves a LOT eth
    ]);
    await network.provider.send("hardhat_setBalance", [
        upgradeManagerAddress,
        "0x1000000000000000000000000", // we are giving ourselves a LOT eth
    ]);

    console.log(`Admin address: ${eSIMWalletAdminAddress}, balance: ${await provider.getBalance(eSIMWalletAdminAddress)}`);
    console.log(`Vault address: ${vaultAddress}, balance: ${await provider.getBalance(eSIMWalletAdminAddress)}`);
    console.log(`Upgrade manager address: ${upgradeManagerAddress}, balance: ${await provider.getBalance(eSIMWalletAdminAddress)}`);

    // 1. Deploy or use existing EntryPoint
    let entryPointAddress;
    if (process.env.ENTRY_POINT_ZERO_POINT_SEVEN_ADDRESS) {
        entryPointAddress = process.env.ENTRY_POINT_ZERO_POINT_SEVEN_ADDRESS;
        console.log(`Using existing EntryPoint at ${entryPointAddress}`);
    } else {
        console.log("Deploying EntryPoint...");
        const EntryPoint = await ethers.getContractFactory("EntryPoint");
        const entryPoint = await EntryPoint.deploy();
        await entryPoint.waitForDeployment();
        entryPointAddress = await entryPoint.getAddress();
        console.log(`EntryPoint deployed to: ${entryPointAddress}`);
    }

    // 2. Deploy P256Verifier
    console.log("Deploying P256Verifier...");
    const P256Verifier = await ethers.getContractFactory("P256Verifier");
    const p256Verifier = await P256Verifier.deploy();
    await p256Verifier.waitForDeployment();
    const p256VerifierAddress = await p256Verifier.getAddress();
    console.log(`P256Verifier deployed to: ${p256VerifierAddress}`);

    // 3. Deploy DeviceWallet implementation
    console.log("Deploying DeviceWallet implementation...");
    const DeviceWallet = await ethers.getContractFactory("DeviceWallet");
    const deviceWalletImpl = await DeviceWallet.deploy(entryPointAddress, p256VerifierAddress);
    const deviceWalletImplAddress = await deviceWalletImpl.getAddress();
    console.log(`DeviceWallet implementation deployed to: ${deviceWalletImplAddress}`);

    // 4. Deploy DeviceWalletFactory with proxy
    console.log("Deploying DeviceWalletFactory with proxy...");
    const DeviceWalletFactory = await ethers.getContractFactory("DeviceWalletFactory");
    const deviceWalletFactory = await upgrades.deployProxy(
        DeviceWalletFactory,
        [
            deviceWalletImplAddress,
            eSIMWalletAdminAddress,
            vaultAddress,
            upgradeManagerAddress,
            entryPointAddress,
            p256VerifierAddress
        ],
        {
            initializer: "initialize",
            kind: "uups",
        }
    );
    await deviceWalletFactory.waitForDeployment();
    const deviceWalletFactoryAddress = await deviceWalletFactory.getAddress();
    console.log(`DeviceWalletFactory proxy deployed to: ${deviceWalletFactoryAddress}`);

    // 5. Deploy ESIMWallet implementation
    console.log("Deploying ESIMWallet implementation...");
    const ESIMWallet = await ethers.getContractFactory("ESIMWallet");
    const esimWalletImpl = await ESIMWallet.deploy();
    await esimWalletImpl.waitForDeployment();
    const esimWalletImplAddress = await esimWalletImpl.getAddress();
    console.log(`ESIMWallet implementation deployed to: ${esimWalletImplAddress}`);

    // 6. Deploy ESIMWalletFactory with proxy
    console.log("Deploying ESIMWalletFactory with proxy...");
    const ESIMWalletFactory = await ethers.getContractFactory("ESIMWalletFactory");
    const esimWalletFactory = await upgrades.deployProxy(
        ESIMWalletFactory,
        [
            esimWalletImplAddress,
            upgradeManagerAddress
        ],
        {
        initializer: "initialize",
        kind: "uups",
        }
    );
    await esimWalletFactory.waitForDeployment();
    const esimWalletFactoryAddress = await esimWalletFactory.getAddress();
    console.log(`ESIMWalletFactory proxy deployed to: ${esimWalletFactoryAddress}`);

    // 7. Deploy Registry with proxy
    console.log("Deploying Registry with proxy...");
    const Registry = await ethers.getContractFactory("Registry");
    const registry = await upgrades.deployProxy(
        Registry,
        [
            eSIMWalletAdminAddress,
            vaultAddress,
            upgradeManagerAddress,
            deviceWalletFactoryAddress,
            esimWalletFactoryAddress,
            entryPointAddress,
            p256VerifierAddress
        ],
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await registry.waitForDeployment();
    const registryAddress = await registry.getAddress();
    console.log(`Registry proxy deployed to: ${registryAddress}`);

    // 8. Deploy LazyWalletRegistry with proxy
    console.log("Deploying LazyWalletRegistry with proxy...");
    const LazyWalletRegistry = await ethers.getContractFactory("LazyWalletRegistry");
    const lazyWalletRegistry = await upgrades.deployProxy(
        LazyWalletRegistry,
        [
            registryAddress,
            upgradeManagerAddress
        ],
        {
            initializer: "initialize",
            kind: "uups",
        }
    );
    await lazyWalletRegistry.waitForDeployment();
    const lazyWalletRegistryAddress = await lazyWalletRegistry.getAddress();
    console.log(`LazyWalletRegistry proxy deployed to: ${lazyWalletRegistryAddress}`);

    // Post-deployment configuration
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
    const tx3 = await esimWalletFactory.connect(upgradeManagerSigner).addRegistryAddress(registryAddress);
    await tx3.wait();
    console.log("Registry address set in ESIMWalletFactory");

    // Deployment summary
    console.log("\n--- DEPLOYMENT SUMMARY ---");
    console.log(`EntryPoint: ${entryPointAddress}`);
    console.log(`P256Verifier: ${p256VerifierAddress}`);
    console.log(`DeviceWallet Implementation: ${deviceWalletImplAddress}`);
    console.log(`ESIMWallet Implementation: ${esimWalletImplAddress}`);
    console.log(`Registry: ${registryAddress}`);
    console.log(`LazyWalletRegistry: ${lazyWalletRegistryAddress}`);
    console.log(`DeviceWalletFactory: ${deviceWalletFactoryAddress}`);
    console.log(`ESIMWalletFactory: ${esimWalletFactoryAddress}`);
    console.log("--- END SUMMARY ---\n");

    console.log("Deployment completed successfully!");
}

main()
.then(() => process.exit(0))
.catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
});

