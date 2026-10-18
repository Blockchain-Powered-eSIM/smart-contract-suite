// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/// @notice Minimal view of the pause a guardian is allowed to raise and release
/// @dev Both are here because a guardian can do both without waiting. Raising one also stays the
///      hot admin key's lever; the guardian's route is what still works while that key is
///      suspended or being replaced.
interface IPausable {
    /// @notice Stops the protocol's guarded purchase and pull paths
    function pause() external;

    /// @notice Clears the pause
    function unpause() external;
}
