// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/// @notice Minimal view of the pause a guardian is allowed to release
/// @dev Only `unpause()` is here. Raising a pause is the hot admin key's lever and releasing one is
///      the timelock's, so the two are deliberately not offered through the same interface.
interface IPausable {
    /// @notice Clears the pause
    function unpause() external;
}
