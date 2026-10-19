// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/// @notice Minimal view of the two-step ownership handover the protocol contracts use
/// @dev The part of OpenZeppelin's `Ownable2Step` a contract taking ownership calls.
interface IOwnable2Step {
    /// @notice Completes a handover the current owner already offered to the caller
    function acceptOwnership() external;

    /// @notice Address the current owner has offered ownership to, or zero
    /// @return The nominated address
    function pendingOwner() external view returns (address);
}
