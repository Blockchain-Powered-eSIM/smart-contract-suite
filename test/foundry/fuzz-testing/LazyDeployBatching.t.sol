// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {FuzzBase} from "test/foundry/fuzz-testing/base/FuzzBase.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Deploying a lazy device's eSIM wallets over an arbitrary number of batches.
/// @dev The eSIM wallet factory salts CREATE2 with the device's base salt plus the wallet's position
///      in the list, so a batch that mis-derives its start index either lands on an address that
///      already holds a wallet or skips one and leaves the device short. The device cursor is the
///      only thing carrying that position between calls, and the batch size is the caller's choice,
///      so the property worth fuzzing is that any sequence of batch sizes ends with each identifier
///      holding one wallet of its own.
///
///      eSIM counts stay small because every wallet is a real BeaconProxy deployment at roughly
///      460,000 gas, and the point is the arithmetic around the cursor rather than the volume.
contract LazyDeployBatchingTest is FuzzBase {

    /// @dev Enough to cross a batch boundary several times without the deployments dominating
    uint256 private constant MAX_FUZZED_ESIMS = 12;

    /// @notice Every eSIM ends with a wallet of its own, whatever the batch sizes were
    /// @dev The distinctness assertion is what catches a start index that restarted rather than
    ///      continuing. That mistake usually reverts on a used CREATE2 address, but a variant that
    ///      derived the salt from the batch position instead of the list position would silently
    ///      hand two identifiers the same address if the collision guard were ever lost.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_deployLazyWallet_everyESIMEndsWithItsOwnWallet(
        uint256 _count,
        uint256 _firstBatch,
        uint256 _laterBatch
    ) public {
        uint256 count = bound(_count, 1, MAX_FUZZED_ESIMS);
        uint256 cap = lazyWalletRegistry.MAX_ESIM_WALLETS_PER_CALL();
        uint256 firstBatch = bound(_firstBatch, 1, cap);
        uint256 laterBatch = bound(_laterBatch, 1, cap);

        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, count);

        vm.prank(eSIMWalletAdmin);
        (address deviceWallet,, uint256 remaining) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            device,
            7001,
            0,
            firstBatch
        );

        uint256 deployed = count > firstBatch ? firstBatch : count;
        assertEq(remaining, count - deployed, "The first batch must report what it left behind");
        assertEq(lazyWalletRegistry.eSIMWalletsDeployed(device), deployed, "The cursor must match the first batch");

        while(remaining > 0) {
            vm.prank(eSIMWalletAdmin);
            (address[] memory batch, uint256 left) = lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(
                device,
                laterBatch
            );

            assertLe(batch.length, laterBatch, "A call must never deploy more than it was asked for");
            assertEq(left, remaining - batch.length, "The remainder must account for what was just deployed");
            remaining = left;
        }

        assertEq(lazyWalletRegistry.eSIMWalletsDeployed(device), count, "Every eSIM must end up with a wallet");
        _assertDistinctWalletsPerESIM(count, deviceWallet);
    }

    /// @notice Once every wallet exists, another call is refused rather than deploying anything more
    /// @dev The terminal revert is what lets a client loop until it is done. A quiet no-op would
    ///      either spin forever or, worse, be read as room for another batch.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_deployMoreESIMWalletsForLazyDevice_stopsOnceTheListIsExhausted(
        uint256 _count,
        uint256 _batch
    ) public {
        uint256 count = bound(_count, 1, MAX_FUZZED_ESIMS);
        uint256 batch = bound(_batch, 1, lazyWalletRegistry.MAX_ESIM_WALLETS_PER_CALL());

        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, count);

        vm.prank(eSIMWalletAdmin);
        (,, uint256 remaining) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            device,
            7101,
            0,
            batch
        );

        while(remaining > 0) {
            vm.prank(eSIMWalletAdmin);
            (, remaining) = lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(device, batch);
        }

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.AllESIMWalletsDeployed.selector, device));
        lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(device, batch);

        assertEq(lazyWalletRegistry.eSIMWalletsDeployed(device), count, "The refused call must move nothing");
    }

    /// @notice A batch outside the cap is always refused, on both entry points
    /// @dev Refusing rather than clamping is what keeps the returned count honest, and it has to hold
    ///      for a request of zero as well: a zero batch would otherwise return success having
    ///      deployed nothing, which a client loop would read as a stall it cannot distinguish from
    ///      completion.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_deployLazyWallet_refusesABatchOutsideTheCap(uint256 _requested) public {
        uint256 cap = lazyWalletRegistry.MAX_ESIM_WALLETS_PER_CALL();
        uint256 requested = bound(_requested, cap + 1, type(uint256).max);

        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 2);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.TooManyESIMWallets.selector, requested, cap));
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 7201, 0, requested);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.TooManyESIMWallets.selector, 0, cap));
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 7202, 0, 0);

        // Nothing above ran far enough to create a device wallet, so the continuation still sees a
        // device it never deployed rather than a cap failure
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.LazyWalletNotDeployed.selector, device));
        lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(device, requested);
    }

    /// @notice Purchase history reaches an eSIM whose wallet exists while its siblings do not
    /// @dev The two cursors are independent by design, one per device and one per eSIM, so a user
    ///      whose first eSIM landed sees its purchases without waiting for the rest of the device.
    ///      An eSIM still waiting for its wallet has to be refused instead, and refused by name
    ///      rather than by writing history into address zero.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_setHistoryForLazyWallet_reachesOnlyTheESIMsThatHaveWallets(
        uint256 _count,
        uint256 _batch
    ) public {
        uint256 count = bound(_count, 2, MAX_FUZZED_ESIMS);
        uint256 batch = bound(_batch, 1, count - 1);

        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, count);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 7301, 0, batch);

        // Every eSIM the batch reached holds the one entry the binding gave it
        for(uint256 i=0; i<batch; ++i) {
            string memory eSIM = _eSIMName(i);

            vm.prank(eSIMWalletAdmin);
            (uint256 copied, uint256 left) = lazyWalletRegistry.setHistoryForLazyWallet(eSIM, 50);

            assertEq(copied, 1, "The eSIM's single entry must be copied");
            assertEq(left, 0, "Nothing must be left waiting");
            assertEq(
                MockESIMWallet(payable(lazyWalletRegistry.lazyDeployedESIMWallet(eSIM)))
                    .getTransactionHistory().length,
                1,
                "The wallet must hold its entry"
            );
        }

        // Every eSIM still waiting for a wallet is refused by name
        for(uint256 i=batch; i<count; ++i) {
            string memory eSIM = _eSIMName(i);

            vm.prank(eSIMWalletAdmin);
            vm.expectRevert(abi.encodeWithSelector(Errors.ESIMWalletNotLazyDeployed.selector, eSIM));
            lazyWalletRegistry.setHistoryForLazyWallet(eSIM, 50);
        }
    }

    /// @notice Every identifier resolves to a distinct wallet the device wallet owns
    function _assertDistinctWalletsPerESIM(uint256 _count, address _deviceWallet) private view {
        address[] memory seen = new address[](_count);

        for(uint256 i=0; i<_count; ++i) {
            address eSIMWallet = lazyWalletRegistry.lazyDeployedESIMWallet(_eSIMName(i));

            assertNotEq(eSIMWallet, address(0), "Every identifier must resolve to a wallet");
            assertEq(
                registry.isESIMWalletValid(eSIMWallet),
                _deviceWallet,
                "Every wallet must be bound to the device wallet"
            );
            assertEq(
                MockESIMWallet(payable(eSIMWallet)).eSIMUniqueIdentifier(),
                _eSIMName(i),
                "Every wallet must carry its own identifier"
            );

            for(uint256 j=0; j<i; ++j) {
                assertNotEq(seen[j], eSIMWallet, "No two identifiers may share a wallet");
            }
            seen[i] = eSIMWallet;
        }
    }

    /// @notice The identifier the binding gives the eSIM at a given position
    function _eSIMName(uint256 _index) private pure returns (string memory) {
        return string.concat("batch_esim_", vm.toString(_index));
    }

    /// @notice Binds `_count` eSIM identifiers to a device, each with one purchase entry
    function _bindESIMs(string memory _device, uint256 _count) private {
        string[] memory devices = new string[](1);
        devices[0] = _device;

        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = new string[](_count);

        DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);
        bundles[0] = new DataBundleDetails[](_count);

        for(uint256 i=0; i<_count; ++i) {
            eSIMs[0][i] = _eSIMName(i);
            bundles[0][i] = DataBundleDetails("DB_BATCH", 1);
        }

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, bundles);
    }
}
