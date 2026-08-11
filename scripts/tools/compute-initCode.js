const hre = require("hardhat");
const {ethers} = hre;
const dotenv = require("dotenv");
const ADDRESS = require("../deployments/address.json");

dotenv.config();

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
    
    const registry = ADDRESS[network.config.name].RegistryProxy;
    const deviceWalletFactoryAddress = ADDRESS[network.config.name].DeviceWalletFactoryProxy;
    const eSIMWalletFactoryAddress = ADDRESS[network.config.name].ESIMWalletFactoryProxy;

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
