// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/// @notice Minimal view of the pause a guardian is allowed to raise and release
/// @dev Both, because a guardian does both without waiting, even while the admin key is suspended.
interface IPausable {
    /// @notice Stops the protocol's guarded purchase and pull paths
    function pause() external;

    /// @notice Clears the pause
    function unpause() external;
}
