// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/// @notice The two things the payment adapter asks the registry on a settlement
/// @dev An interface rather than an import of `Registry`, which already imports the adapter. It
///      also keeps the adapter's view of the registry down to what it reads.
interface IPaymentRegistry {
    /// @notice Address that receives payments for data bundles
    function vault() external view returns (address);

    /// @notice The device wallet an eSIM wallet belongs to, or zero if the registry has no record
    function isESIMWalletValid(address eSIMWallet) external view returns (address);
}
