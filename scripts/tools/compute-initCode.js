const hre = require("hardhat");
const {ethers, network} = hre;
const dotenv = require("dotenv");
const ADDRESS = require("../../deployments/address.json");

dotenv.config();

// The deployment record is keyed by chain name, chain id and EntryPoint version together, so that
// a mainnet entry can never sit where a testnet one was and a v0.8 deployment can never sit where
// a v0.7 one still in use was. Built the same way DeployConfig.recordKey does it.
const ENTRY_POINT_TAG = "entrypoint-v8";

const CHAIN_LABELS = {
    1: "mainnet",
    10: "optimism",
    8453: "base",
    11155111: "sepolia",
    11155420: "optimism-sepolia",
    84532: "base-sepolia",
    31337: "anvil",
};

function recordFor(chainId) {
    const key = `${CHAIN_LABELS[chainId] ?? "chain"}-${chainId}-${ENTRY_POINT_TAG}`;
    const entry = ADDRESS[key];
    if (!entry) throw new Error(`No deployment recorded under ${key}`);
    return entry;
}

async function main () {

    const {
        keccak256,
        getCreate2Address,
        concat,
        toBigInt,
        hexlify,
        toBeHex,
        zeroPadValue
    } = ethers;

    const provider = new ethers.JsonRpcProvider(network.config.url);

    const ESIM_WALLET_ADMIN = process.env.ESIM_WALLET_ADMIN;
    const eSIMWalletAdminSigner = new ethers.Wallet(process.env.PRIVATE_KEY_3, provider);

    // Sample values
    const deviceWalletOwnerKey = ["0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C291", "0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F1"];
    const deviceUniqueIdentifier = "Device_11";
    const salt = 111n; // bigint or number
    
    const deployment = recordFor(network.config.chainId);
    const registry = deployment.contracts.RegistryProxy.address;
    const deviceWalletFactoryAddress = deployment.contracts.DeviceWalletFactoryProxy.address;
    const eSIMWalletFactoryAddress = deployment.contracts.ESIMWalletFactoryProxy.address;

    console.log("registry: ", registry);
    console.log("deviceWalletFactoryAddress: ", deviceWalletFactoryAddress);

    const factory = await ethers.getContractAt("DeviceWalletFactory", deviceWalletFactoryAddress);
    const beacon = await factory.beacon();
    console.log("Beacon Proxy address: ", beacon);

    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    const saltBytes32 = zeroPadValue(toBeHex(salt), 32);

    // Encode the DeviceWallet.init with the init params
    const DeviceWallet = await ethers.getContractFactory("DeviceWallet");
    const deviceWalletInitData = DeviceWallet.interface.encodeFunctionData("init", [
        registry,
        deviceWalletOwnerKey,
        deviceUniqueIdentifier,
        eSIMWalletFactoryAddress
    ]);

    const beaconProxyBytecode = (await ethers.getContractFactory("@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol:BeaconProxy")).bytecode;
    console.log("beaconProxyBytecode: ", beaconProxyBytecode, "\n");

    // Encode BeaconProxy constructor args
    const beaconProxyConstructorArgs = abiCoder.encode(
        ["address", "bytes"],
        [beacon, deviceWalletInitData]
    );
    console.log("beaconProxyConstructorArgs: ", beaconProxyConstructorArgs);
    
    // Compute initCode
    const initCode = concat([beaconProxyBytecode, beaconProxyConstructorArgs]);
    console.log("\ninitCode: ", initCode);
    
    // Hash init code
    const initCodeHash = keccak256(initCode);
    console.log("initCodeHash: ", initCodeHash, "\n");

    // Calculate deterministic address from init code hash
    const create2Address = getCreate2Address(deviceWalletFactoryAddress, saltBytes32, initCodeHash);
    console.log("Off-chain Create2 address:", create2Address);

    const deviceWalletFactory = await ethers.getContractAt("DeviceWalletFactory", deviceWalletFactoryAddress);
    const onChainCounterfactualAddress = await deviceWalletFactory.connect(eSIMWalletAdminSigner).getCounterFactualAddress(
        deviceWalletOwnerKey,
        deviceUniqueIdentifier,
        salt
    );
    console.log("Device wallet counterfactualAddress: ", onChainCounterfactualAddress, onChainCounterfactualAddress == create2Address);

    return;

    console.log("Calling createAccount from Device wallet factory");
    const tx = await deviceWalletFactory.connect(eSIMWalletAdminSigner).createAccount(
        deviceUniqueIdentifier,
        deviceWalletOwnerKey,
        salt
    );
    await tx.wait();
    console.log("Device wallet deployed: ", tx);
}

main();
