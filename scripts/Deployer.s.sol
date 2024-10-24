pragma solidity ^0.8.18;

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {P256Verifier} from "../contracts/P256Verifier.sol";
import {ESIMWalletFactory} from "../contracts/esim-wallet/ESIMWalletFactory.sol";

// SPDX-License-Identifier: MIT

contract Deployer is Script {

    event AdminAdded(address indexed _admin);

    event P256VerifierDeployed(address indexed p256Verifier);

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        deployESIMWalletFactory(registryContract, upgradeManager);

        vm.stopBroadcast();
    }

    function deployP256verifier() public {
        address p256Verifier = address(new P256Verifier());

        console.log("p256Verifier: ", p256Verifier);
    }

    function deployDeviceWalletImpl() onlyAdmin external returns (address) {

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
}