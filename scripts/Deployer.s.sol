pragma solidity ^0.8.18;

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Script} from "forge-std/Script.sol";

import {P256Verifier} from "../contracts/P256Verifier.sol";

// SPDX-License-Identifier: MIT

contract Deployer is Script {

    event AdminAdded(address indexed _admin);

    event P256VerifierDeployed(address indexed p256Verifier);

    address public admin;

    P256Verifier public p256Verifier;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Unauthorised");
    }

    constructor(address _admin) {
        require(_admin != address(0), "_admin 0");

        admin = _admin;
        emit AdminAdded(_admin);
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // NFT nft = new NFT("NFT_tutorial", "TUT", "baseUri");

        vm.stopBroadcast();
    }

    function deployP256verifier() onlyAdmin external returns (address) {
        p256Verifier = new P256Verifier();

        emit P256VerifierDeployed(address(p256Verifier));
    }

    function deployDeviceWalletImpl() onlyAdmin external returns (address) {

    }
}