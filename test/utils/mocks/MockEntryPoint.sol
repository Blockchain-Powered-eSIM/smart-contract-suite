// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IAccount} from "@account-abstraction/contracts/interfaces/IAccount.sol";
import {ValidationData, _parseValidationData} from "@account-abstraction/contracts/core/Helpers.sol";
import "./MockStakeManager.sol";
import "./MockNonceManager.sol";

contract MockEntryPoint is IEntryPoint, MockStakeManager, MockNonceManager {
    mapping(address => uint256) public nonces;

    // Events for verification purposes in tests
    event MockHandleOpsCalled();
    event MockHandleAggregatedOpsCalled();

    /// @notice Validates each operation and rejects the batch on failure, the way the real
    ///         EntryPoint does. It does not execute the call, charge gas or pay a beneficiary,
    ///         because no test needs those and simulating them would only invite trusting them.
    function handleOps(
        PackedUserOperation[] calldata ops,
        address payable /* beneficiary */
    ) external override {
        for (uint256 i = 0; i < ops.length; ++i) {
            uint256 validationData = IAccount(ops[i].sender).validateUserOp(ops[i], getUserOpHash(ops[i]), 0);
            ValidationData memory parsed = _parseValidationData(validationData);

            // Anything other than address(0) is either SIG_VALIDATION_FAILED or an aggregator this
            // mock does not know how to call, and both stop the operation here
            if (parsed.aggregator != address(0)) {
                revert FailedOp(i, "AA24 signature error");
            }
            if (block.timestamp > parsed.validUntil || block.timestamp < parsed.validAfter) {
                revert FailedOp(i, "AA22 expired or not due");
            }
        }

        emit MockHandleOpsCalled();
    }

    function handleAggregatedOps(
        UserOpsPerAggregator[] calldata /* opsPerAggregator */,
        address payable /* beneficiary */
    ) external override {
        emit MockHandleAggregatedOpsCalled();
    }

    /// @notice A hash that is distinct per operation, chain and entry point.
    /// @dev Deliberately not the ERC-4337 derivation. The real one is EIP-712 domain separated
    ///      over the whole packed operation, and reimplementing it here would give a second copy
    ///      that can drift without anything noticing. Whether the wallet agrees with the real
    ///      derivation is what the fork test against the deployed singleton is for. What this has
    ///      to get right is being injective, so a signature for one operation cannot validate
    ///      another. It previously returned one constant for every operation.
    function getUserOpHash(
        PackedUserOperation calldata userOp
    ) public view override returns (bytes32) {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                keccak256(userOp.paymasterAndData),
                block.chainid,
                address(this)
            )
        );
    }

    function getSenderAddress(
        bytes memory /* initCode */
    ) external view override {
        revert SenderAddressResult(address(this));
    }

    function delegateAndRevert(
        address /* target */,
        bytes calldata /* data */
    ) external pure override {
        revert DelegateAndRevert(true, "MockDelegateCall");
    }

    /// @notice The real EntryPoint deploys a SenderCreator helper in its constructor and calls
    ///         initCode through it. No test exercises that path, so the mock reports address(0)
    ///         rather than deploying one. A test that needs sender creation has to override this.
    function senderCreator() external pure override returns (ISenderCreator) {
        return ISenderCreator(address(0));
    }

    // Add mock implementations for required methods from inherited interfaces
    function incrementNonce(address user) external {
        nonces[user]++;
    }

    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    // Additional methods to mock IStakeManager and INonceManager methods as needed
}
