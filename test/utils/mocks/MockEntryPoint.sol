// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "./MockStakeManager.sol";
import "./MockNonceManager.sol";

contract MockEntryPoint is IEntryPoint, MockStakeManager, MockNonceManager {
    mapping(address => uint256) public nonces;

    // Events for verification purposes in tests
    event MockHandleOpsCalled();
    event MockHandleAggregatedOpsCalled();

    function handleOps(
        PackedUserOperation[] calldata /* ops */,
        address payable /* beneficiary */
    ) external override {
        emit MockHandleOpsCalled();
    }

    function handleAggregatedOps(
        UserOpsPerAggregator[] calldata /* opsPerAggregator */,
        address payable /* beneficiary */
    ) external override {
        emit MockHandleAggregatedOpsCalled();
    }

    function getUserOpHash(
        PackedUserOperation calldata /* userOp */
    ) external pure override returns (bytes32) {
        return keccak256("MockUserOpHash");
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
