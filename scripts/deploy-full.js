const { ethers, upgrades } = require("hardhat");
const dotenv = require("dotenv");

dotenv.config();

async function main() {
    console.log("Starting deployment script...");

    // Get deployer account
    const [deployer] = await ethers.getSigners();
    console.log(`Deploying contracts with account: ${deployer.address}`);
    console.log(`Account balance: ${ethers.formatEther(await deployer.provider.getBalance(deployer.address))} ETH`);

    // Check for required environment variables
    const adminAddress = process.env.ESIM_WALLET_ADMIN;
    const vaultAddress = process.env.VAULT;
    const upgradeManagerAddress = process.env.UPGRADE_MANAGER;

    console.log(`Admin address: ${adminAddress}`);
    console.log(`Vault address: ${vaultAddress}`);
    console.log(`Upgrade manager address: ${upgradeManagerAddress}`);

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
            adminAddress,
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
            adminAddress,
            vaultAddress,
            upgradeManagerAddress,
            deviceWalletFactory,
            esimWalletFactoryAddress,
            entryPointAddress,
            p256VerifierAddress
        ],
        {
            initializer: "initialize",
            kind: "uups",
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

    // 1. Set factories on Registry
    console.log("Setting factories on Registry...");
    const setFactoriesTx = await registry.setFactories(
        deviceWalletFactoryAddress,
        esimWalletFactoryAddress
    );
    await setFactoriesTx.wait();
    console.log("Factories set on Registry");

    // 2. Set registries on factories
    console.log("Setting registry on DeviceWalletFactory...");
    const setDeviceRegistryTx = await deviceWalletFactory.setRegistry(registryAddress);
    await setDeviceRegistryTx.wait();
    console.log("Registry set on DeviceWalletFactory");

    console.log("Setting registry on ESIMWalletFactory...");
    const setEsimRegistryTx = await esimWalletFactory.setRegistry(registryAddress);
    await setEsimRegistryTx.wait();
    console.log("Registry set on ESIMWalletFactory");

    // 3. Set LazyWalletRegistry on Registry
    console.log("Setting LazyWalletRegistry on Registry...");
    const setLazyRegistryTx = await registry.setLazyWalletRegistry(lazyWalletRegistryAddress);
    await setLazyRegistryTx.wait();
    console.log("LazyWalletRegistry set on Registry");

    // 4. Set Registry on LazyWalletRegistry
    console.log("Setting Registry on LazyWalletRegistry...");
    const setRegistryTx = await lazyWalletRegistry.setRegistry(registryAddress);
    await setRegistryTx.wait();
    console.log("Registry set on LazyWalletRegistry");

    // 5. Set vault addresses
    console.log("Setting vault address on DeviceWalletFactory...");
    const setDeviceVaultTx = await deviceWalletFactory.setVault(vaultAddress);
    await setDeviceVaultTx.wait();
    console.log("Vault address set on DeviceWalletFactory");

    console.log("Setting vault address on ESIMWalletFactory...");
    const setEsimVaultTx = await esimWalletFactory.setVault(vaultAddress);
    await setEsimVaultTx.wait();
    console.log("Vault address set on ESIMWalletFactory");

    // 6. Set upgradeManager if different from admin
    if (upgradeManagerAddress !== adminAddress) {
        console.log("Setting upgrade manager role...");
        
        const UPGRADER_ROLE = await registry.UPGRADER_ROLE();
        
        console.log("Setting upgrade manager on Registry...");
        const grantRegistryUpgraderTx = await registry.grantRole(UPGRADER_ROLE, upgradeManagerAddress);
        await grantRegistryUpgraderTx.wait();
        
        console.log("Setting upgrade manager on LazyWalletRegistry...");
        const grantLazyRegistryUpgraderTx = await lazyWalletRegistry.grantRole(UPGRADER_ROLE, upgradeManagerAddress);
        await grantLazyRegistryUpgraderTx.wait();
        
        console.log("Setting upgrade manager on DeviceWalletFactory...");
        const grantDeviceFactoryUpgraderTx = await deviceWalletFactory.grantRole(UPGRADER_ROLE, upgradeManagerAddress);
        await grantDeviceFactoryUpgraderTx.wait();
        
        console.log("Setting upgrade manager on ESIMWalletFactory...");
        const grantEsimFactoryUpgraderTx = await esimWalletFactory.grantRole(UPGRADER_ROLE, upgradeManagerAddress);
        await grantEsimFactoryUpgraderTx.wait();
        
        console.log("Upgrade manager role granted to:", upgradeManagerAddress);
    }

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

