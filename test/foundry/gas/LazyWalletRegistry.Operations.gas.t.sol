// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/CustomStructs.sol";

import {GasBase} from "test/foundry/gas/base/GasBase.sol";

/// @notice Gas for the lazy deployment path, across the batch sizes the caller gets to choose.
/// @dev Both batched calls take a size and clamp it to what is left, so the caller decides how much
///      of a device lands in one transaction. The sizes below trace the curve: the fixed cost sits
///      in the batch of one, and every step after it is close to pure per-wallet cost. That is what
///      the backend needs to size a transaction against a block limit, and it is the number the
///      whole batching change exists to make visible.
contract LazyWalletRegistryOperationsGasTest is GasBase {

    string internal NAMESPACE = "LazyWalletRegistry.Operations";

    /// @dev The device the batch curve is measured against holds more eSIMs than one call can
    ///      deploy, so the first call always leaves a remainder.
    uint256 private constant ESIMS_PER_DEVICE = 25;

    /// @notice Writing eSIM identifiers and their history against lazy devices
    function test_batchPopulateHistory() public {
        string[] memory oneDevice = new string[](1);
        oneDevice[0] = customDeviceUniqueIdentifiers[0];

        string[][] memory oneDeviceESIMs = new string[][](1);
        oneDeviceESIMs[0] = customESIMUniqueIdentifiers[0];

        DataBundleDetails[][] memory oneDeviceBundles = new DataBundleDetails[][](1);
        oneDeviceBundles[0] = customDataBundleDetails[0];

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(oneDevice, oneDeviceESIMs, oneDeviceBundles);
        vm.snapshotGasLastCall(NAMESPACE, "batchPopulateHistory: 1 device, 5 eSIMs");

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(
            customDeviceUniqueIdentifiers,
            customESIMUniqueIdentifiers,
            customDataBundleDetails
        );
        vm.snapshotGasLastCall(NAMESPACE, "batchPopulateHistory: 5 devices, 22 eSIMs");
    }

    /// @notice The first deploy for a device, at four batch sizes
    /// @dev Each size gets its own device because a device only ever has one first batch. The
    ///      difference between the sizes is per-wallet cost; the batch of one is where the device
    ///      wallet, the registry bindings and the salt reservation are all paid for.
    function test_deployLazyWalletAndSetESIMIdentifier_acrossBatchSizes() public {
        uint256[4] memory sizes = [uint256(1), 5, 10, 20];
        string[4] memory labels = [
            "deployLazyWalletAndSetESIMIdentifier: batch of 1",
            "deployLazyWalletAndSetESIMIdentifier: batch of 5",
            "deployLazyWalletAndSetESIMIdentifier: batch of 10",
            "deployLazyWalletAndSetESIMIdentifier: batch of 20"
        ];

        for(uint256 i = 0; i < sizes.length; ++i) {
            string memory device = customDeviceUniqueIdentifiers[i];
            _bindESIMs(device, ESIMS_PER_DEVICE, 1);

            vm.prank(eSIMWalletAdmin);
            lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
                listOfOwnerKeys[i],
                device,
                9000 + (i * 1000),
                0,
                sizes[i]
            );
            vm.snapshotGasLastCall(NAMESPACE, labels[i]);
        }
    }

    /// @notice A follow-up batch, which pays no device wallet cost at all
    /// @dev The gap between this and the first call at the same size is the fixed cost of starting a
    ///      device. A client looping until `remaining` reaches zero pays it once.
    function test_deployMoreESIMWalletsForLazyDevice_acrossBatchSizes() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, ESIMS_PER_DEVICE, 1);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 9500, 0, 1);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(device, 1);
        vm.snapshotGasLastCall(NAMESPACE, "deployMoreESIMWalletsForLazyDevice: batch of 1");

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(device, 5);
        vm.snapshotGasLastCall(NAMESPACE, "deployMoreESIMWalletsForLazyDevice: batch of 5");

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(device, 18);
        vm.snapshotGasLastCall(NAMESPACE, "deployMoreESIMWalletsForLazyDevice: batch of 18");
    }

    /// @notice Copying a lazy eSIM's purchase history onto its wallet, in batches
    /// @dev History is copied after the wallet exists rather than during deployment, so this cost is
    ///      separate from every deploy number above and a device with a long history pays it over as
    ///      many calls as it needs.
    function test_setHistoryForLazyWallet_acrossBatchSizes() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 1, 50);
        string memory eSIM = _eSIMName(device, 0);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 9600, 0, 1);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.setHistoryForLazyWallet(eSIM, 1);
        vm.snapshotGasLastCall(NAMESPACE, "setHistoryForLazyWallet: 1 entry");

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.setHistoryForLazyWallet(eSIM, 10);
        vm.snapshotGasLastCall(NAMESPACE, "setHistoryForLazyWallet: 10 entries");

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.setHistoryForLazyWallet(eSIM, 39);
        vm.snapshotGasLastCall(NAMESPACE, "setHistoryForLazyWallet: 39 entries");
    }
}
