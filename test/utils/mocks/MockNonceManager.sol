// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@account-abstraction/contracts/interfaces/INonceManager.sol";

contract MockNonceManager is INonceManager {
    // Mapping to store nonces by sender and key
    mapping(address => mapping(uint192 => uint256)) private nonces;

    /**
     * Returns the next nonce for the specified sender and key.
     * @param sender The account address.
     * @param key The high 192 bits of the nonce.
     * @return nonce The full nonce for the next UserOp with this sender.
     */
    function getNonce(address sender, uint192 key) 
        external 
        view 
        override 
        returns (uint256 nonce) 
    {
        return nonces[sender][key];
    }

    /**
     * Manually increments the nonce for the specified sender and key.
     * @param key The high 192 bits of the nonce.
     */
    function incrementNonce(uint192 key) external override {
        nonces[msg.sender][key]++;
    }

    // Helper function to set a specific nonce, useful for testing purposes
    function setNonce(address sender, uint192 key, uint256 newNonce) external {
        nonces[sender][key] = newNonce;
    }
}
