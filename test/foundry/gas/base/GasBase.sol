// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Shared setup for the files that record gas per operation.
/// @dev Every file under this folder measures single calls with `vm.snapshotGasLastCall` and writes
///      one JSON file named after its own namespace. That is a different thing from `.gas-snapshot`,
///      which records the total cost of a whole test body: a guard-path entry there is dominated by
///      whatever the body deployed, so it cannot say what the guard itself costs. Both baselines are
///      kept, and this folder is excluded from the `.gas-snapshot` filters so the two do not overlap.
///
///      Nothing here asserts. A file in this folder fails when a call reverts, and the assertions
///      that say a call did the right thing live in the unit tests. Setup that a measurement does
///      not want counted belongs in a helper below, not inline next to the call being measured.
abstract contract GasBase is DeployerBase {

    /// @dev Owner keys have to be real points on the P256 curve, `DeviceWalletFactory.sol:299`
    ///      rejects anything else, so the batch measurements are capped at the five the fixture
    ///      carries rather than generating more.
    uint256 internal constant AVAILABLE_OWNER_KEYS = 5;

    /// @notice Deploys one device wallet and its first eSIM wallet through the admin path
    /// @param _identifier Device identifier to deploy against
    /// @param _keyIndex Which of the fixture owner keys to use, below AVAILABLE_OWNER_KEYS
    /// @param _salt Salt fixing the counterfactual address
    function _deployDeviceWallet(
        string memory _identifier,
        uint256 _keyIndex,
        uint256 _salt
    ) internal returns (MockDeviceWallet deviceWallet, MockESIMWallet eSIMWallet) {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        identifiers[0] = _identifier;
        keys[0] = listOfOwnerKeys[_keyIndex];
        salts[0] = _salt;
        deposits[0] = 0;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            identifiers,
            keys,
            salts,
            deposits
        );

        deviceWallet = MockDeviceWallet(payable(wallets[0].deviceWallet));
        eSIMWallet = MockESIMWallet(payable(wallets[0].eSIMWallet));
    }

    /// @notice Builds the four parallel arrays the admin deploy path takes
    /// @dev Key index and salt both follow the position in the batch, so every entry is distinct and
    ///      no two land on the same counterfactual address.
    /// @param _count Entries in the batch, at most AVAILABLE_OWNER_KEYS
    /// @param _prefix Identifier prefix, so two batches in one test body cannot collide
    /// @param _baseSalt Salt the first entry uses
    function _batch(
        uint256 _count,
        string memory _prefix,
        uint256 _baseSalt
    ) internal view returns (
        string[] memory identifiers,
        bytes32[2][] memory keys,
        uint256[] memory salts,
        uint256[] memory deposits
    ) {
        identifiers = new string[](_count);
        keys = new bytes32[2][](_count);
        salts = new uint256[](_count);
        deposits = new uint256[](_count);

        for(uint256 i = 0; i < _count; ++i) {
            identifiers[i] = string.concat(_prefix, vm.toString(i));
            keys[i] = listOfOwnerKeys[i];
            salts[i] = _baseSalt + i;
            deposits[i] = 0;
        }
    }

    /// @notice Binds eSIM identifiers to a lazy device, with one history entry each per pass
    /// @dev `batchPopulateHistory` pairs identifiers with bundles by position, so one call writes at
    ///      most one entry per eSIM. More history means calling it again, which is what
    ///      `_entriesPerESIM` above one does.
    /// @param _device Device identifier the eSIMs belong to
    /// @param _count How many eSIM identifiers to bind
    /// @param _entriesPerESIM History entries to write against each of them
    function _bindESIMs(string memory _device, uint256 _count, uint256 _entriesPerESIM) internal {
        string[] memory devices = new string[](1);
        devices[0] = _device;

        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = new string[](_count);

        DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);
        bundles[0] = new DataBundleDetails[](_count);

        for(uint256 i = 0; i < _count; ++i) {
            eSIMs[0][i] = _eSIMName(_device, i);
            bundles[0][i] = DataBundleDetails("DB_GAS", 1);
        }

        for(uint256 pass = 0; pass < _entriesPerESIM; ++pass) {
            vm.prank(eSIMWalletAdmin);
            lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, bundles);
        }
    }

    /// @notice The eSIM identifier at a position under a device
    function _eSIMName(string memory _device, uint256 _index) internal pure returns (string memory) {
        return string.concat(_device, "_eSIM_", _toString(_index));
    }

    /// @dev `vm.toString` would do, but it is a cheatcode call inside loops that sit next to
    ///      measured spans, and keeping the helpers free of cheatcodes keeps the spans clean.
    function _toString(uint256 _value) private pure returns (string memory) {
        if(_value == 0) return "0";

        uint256 digits;
        uint256 counter = _value;
        while(counter != 0) {
            ++digits;
            counter /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while(_value != 0) {
            --digits;
            buffer[digits] = bytes1(uint8(48 + (_value % 10)));
            _value /= 10;
        }

        return string(buffer);
    }
}
