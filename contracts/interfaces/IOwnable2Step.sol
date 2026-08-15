// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/// @notice Minimal view of the two-step ownership handover the protocol contracts use
/// @dev Matches the part of OpenZeppelin's `Ownable2Step` an incoming owner needs. The offer is made
///      by the current owner and completed by the nominee, so a contract taking ownership only ever
///      calls these two.
interface IOwnable2Step {
    /// @notice Completes a handover the current owner already offered to the caller
    function acceptOwnership() external;

    /// @notice Address the current owner has offered ownership to, or zero
    /// @return The nominated address
    function pendingOwner() external view returns (address);
}
