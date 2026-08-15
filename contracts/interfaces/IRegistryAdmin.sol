// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/// @notice Minimal view of the admin role the protocol owner controls
/// @dev Holds only the two calls `ProtocolAdmin` makes. `enableAdmin` is deliberately absent: the
///      owner reaches it as an ordinary scheduled payload, and putting it here would invite a
///      named function beside the guardian's, which is the one place a fast path could be added by
///      accident. Suspending is instant and restoring waits, and the split is what stops a
///      compromised key from undoing its own suspension.
interface IRegistryAdmin {
    /// @notice Suspends the admin's powers protocol-wide, leaving its address on the books
    function disableAdmin() external;

    /// @notice Nominates a new admin, which strips the incumbent until the nominee accepts
    /// @param _newAdmin Address of the recipient to receive the admin role
    function requestAdminUpdate(address _newAdmin) external;
}
