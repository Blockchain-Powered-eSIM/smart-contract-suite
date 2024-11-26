pragma solidity ^0.8.18;
// SPDX-License-Identifier: MIT

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import {P256Verifier} from "../contracts/P256Verifier.sol";
import {ESIMWalletFactory} from "../contracts/esim-wallet/ESIMWalletFactory.sol";
import {DeviceWalletFactory} from "../contracts/device-wallet/DeviceWalletFactory.sol";
import {Registry} from "../contracts/Registry.sol";
import {DeviceWallet} from "../contracts/device-wallet/DeviceWallet.sol";

contract Deployer is Script {

    event AdminAdded(address indexed _admin);

    event P256VerifierDeployed(address indexed p256Verifier);

    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        console.log("deployerAddress: ", deployerAddress);

        vm.startBroadcast(deployerPrivateKey);

        deployESIMWalletFactory(registryContract, upgradeManager);

        vm.stopBroadcast();
    }

    function deployP256verifier() public {
        address p256Verifier = address(new P256Verifier());

        console.log("p256Verifier: ", p256Verifier);
    }

    function deployDeviceWalletImpl(
        IEntryPoint entryPoint,
        P256Verifier verifier
    ) external {
        address deviceWalletImpl = new DeviceWallet(entryPoint, verifier);
        
        console.log("deviceWalletImpl: ", deviceWalletImpl);
    }

    function deployRegistry() public {
        Options memory opts;

        address eSIMWalletFactoryProxy = new Upgrades.deployUUPSProxy(
            Registry,
            abi.encodeCall(
                Registry.initialize,
                (
                    registryContract,
                    upgradeManager
                )
            ),
            opts
        );
        
        console.log("eSIMWalletFactoryProxy: ", eSIMWalletFactoryProxy);
    }

    function deployESIMWalletFactory(
        address registryContract,
        address upgradeManager
    ) public {

        /** 
        struct Options {
            string referenceContract;
            string referenceBuildInfoDir;
            bytes constructorData;
            string[] exclude;
            string unsafeAllow;
            bool unsafeAllowRenames;
            bool unsafeSkipProxyAdminCheck;
            bool unsafeSkipStorageCheck;
            bool unsafeSkipAllChecks;
            struct DefenderOptions defender;
        }
        */
        Options memory opts;

        address eSIMWalletFactoryProxy = new Upgrades.deployUUPSProxy(
            ESIMWalletFactory,
            abi.encodeCall(
                ESIMWalletFactory.initialize,
                (
                    registryContract,
                    upgradeManager
                )
            ),
            opts
        );
        
        console.log("eSIMWalletFactoryProxy: ", eSIMWalletFactoryProxy);
    }

    function deployDeviceWalletFactory(
        address registryContract,
        address eSIMWalletAdmin,
        address vault,
        address upgradeManager
    ) public {

        /** 
        struct Options {
            string referenceContract;
            string referenceBuildInfoDir;
            bytes constructorData;
            string[] exclude;
            string unsafeAllow;
            bool unsafeAllowRenames;
            bool unsafeSkipProxyAdminCheck;
            bool unsafeSkipStorageCheck;
            bool unsafeSkipAllChecks;
            struct DefenderOptions defender;
        }
        */
        Options memory opts;

        address deviceWalletFactoryProxy = new Upgrades.deployUUPSProxy(
            DeviceWalletFactory,
            abi.encodeCall(
                DeviceWalletFactory.initialize,
                (
                    registryContract,
                    eSIMWalletAdmin,
                    vault,
                    upgradeManager
                )
            ),
            opts
        );
        
        console.log("deviceWalletFactoryProxy: ", deviceWalletFactoryProxy);
    }
}