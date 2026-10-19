// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/// @notice Minimal view of the admin role the protocol owner controls
/// @dev Holds only what `ProtocolAdmin` calls. `enableAdmin` is left out (the owner reaches it as a
///      scheduled payload) so no instant restore is added by accident: suspending is instant and
///      restoring waits, which stops a compromised key undoing its own suspension.
interface IRegistryAdmin {
    /// @notice Suspends the admin's powers protocol-wide, leaving its address on the books
    function disableAdmin() external;

    /// @notice Nominates a new admin, which strips the incumbent until the nominee accepts
    /// @param _newAdmin Address of the recipient to receive the admin role
    function requestAdminUpdate(address _newAdmin) external;

    /// @notice The admin address on the books, whether or not its powers are live
    function adminOfRecord() external view returns (address);
}
