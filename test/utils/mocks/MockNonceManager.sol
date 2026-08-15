// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {INonceManager} from "@account-abstraction/contracts/interfaces/INonceManager.sol";

/// @notice Stand-in for the EntryPoint's two-dimensional nonce accounting
contract MockNonceManager is INonceManager {
    // Mapping to store nonces by sender and key
    mapping(address => mapping(uint192 => uint256)) private nonces;

    /// @notice Returns the next nonce for the specified sender and key
    /// @param sender The account address
    /// @param key The high 192 bits of the nonce
    /// @return nonce The full nonce for the next user operation from this sender
    function getNonce(address sender, uint192 key) 
        external 
        view 
        override 
        returns (uint256 nonce) 
    {
        return nonces[sender][key];
    }

    /// @notice Manually increments the nonce for the caller and the given key
    /// @param key The high 192 bits of the nonce
    function incrementNonce(uint192 key) external override {
        nonces[msg.sender][key]++;
    }

    /// @notice Sets a specific nonce, so a test can start from an arbitrary position
    function setNonce(address sender, uint192 key, uint256 newNonce) external {
        nonces[sender][key] = newNonce;
    }
}
