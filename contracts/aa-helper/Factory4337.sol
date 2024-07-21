pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "./Account4337.sol";

contract Factory4337 {
    Account4337 public immutable accountImplementation;

    constructor(IEntryPoint _entryPoint) {
        accountImplementation = new Account4337(_entryPoint);
    }

    /**
     * create an account, and return its address.
     * returns the address even if the account is already deployed.
     * Note that during UserOperation execution, this method is called only if the account is not deployed.
     * This method returns an existing account address so that entryPoint.getSenderAddress() would work even after account creation
     */
    function createAccount(address owner,uint256 salt) public returns (Account4337 ret) {
        address addr = getAddress(owner, salt);
        uint256 codeSize = addr.code.length;
        if (codeSize > 0) {
            return Account4337(payable(addr));
        }
        ret = Account4337(payable(new ERC1967Proxy{salt : bytes32(salt)}(
            address(accountImplementation),
            abi.encodeCall(Account4337.initialize, (owner))
        )));
    }

    /**
     * calculate the counterfactual address of this account as it would be returned by createAccount()
     */
    function getAddress(address owner,uint256 salt) public view returns (address) {
        return Create2.computeAddress(bytes32(salt), keccak256(abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(
                address(accountImplementation),
                abi.encodeCall(Account4337.initialize, (owner))
            )
        )));
    }
}
