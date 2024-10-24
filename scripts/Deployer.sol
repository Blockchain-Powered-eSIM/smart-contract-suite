pragma solidity ^0.8.18;

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {P256Verifier} from "../contracts/P256Verifier.sol";

// SPDX-License-Identifier: MIT

contract Deployer {

    event AdminAdded(address indexed _admin);

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

    function deployP256verifier() onlyAdmin external returns (address) {
        p256Verifier = 
    }

    function deployDeviceWalletImpl() onlyAdmin external returns (address) {

    }
}