// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";

/// @notice Shared setup for the device wallet factory tests.
/// @dev The deploy paths take four parallel arrays, so almost every test needs the same one-entry
///      batch built, and almost every one has to say where a deposit ended up.
abstract contract DeviceWalletFactoryFixture is DeployerBase {

    /// @notice Builds a one-entry batch, since the four arrays have to agree in length
    /// @param _identifier The device identifier to deploy against
    /// @param _key The P256 owner key
    /// @param _salt Salt fixing the counterfactual address
    /// @param _deposit ETH to fund the deployed wallet with
    function _singleEntryBatch(
        string memory _identifier,
        bytes32[2] memory _key,
        uint256 _salt,
        uint256 _deposit
    ) internal pure returns (
        string[] memory identifiers,
        bytes32[2][] memory keys,
        uint256[] memory salts,
        uint256[] memory deposits
    ) {
        identifiers = new string[](1);
        keys = new bytes32[2][](1);
        salts = new uint256[](1);
        deposits = new uint256[](1);

        identifiers[0] = _identifier;
        keys[0] = _key;
        salts[0] = _salt;
        deposits[0] = _deposit;
    }

    /// @notice A deposit made on a wallet's behalf is held by the wallet, not by the entry point
    /// @dev An entry point balance here would mean the ETH is reserved for gas and unreachable for
    ///      everything else the owner wants to spend it on, which is the behaviour this replaced.
    function _assertDepositHeldByWallet(address _deviceWallet, uint256 _deposit) internal view {
        assertEq(_deviceWallet.balance, _deposit, "The wallet should hold the deposit itself");
        assertEq(
            entryPoint.balanceOf(_deviceWallet),
            0,
            "The entry point should hold no deposit for the wallet"
        );
    }
}
