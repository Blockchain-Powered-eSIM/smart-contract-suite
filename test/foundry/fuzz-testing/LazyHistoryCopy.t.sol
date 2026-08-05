// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {FuzzBase} from "test/foundry/fuzz-testing/base/FuzzBase.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Copying a lazy wallet's purchase history over an arbitrary number of batches.
/// @dev The wallet appends whatever batch it is handed and no longer refuses a second call, so
///      nothing inside it stops the same entries being written twice. The registry's cursor is the
///      only thing that does, and the batch size is the caller's choice, so the property worth
///      fuzzing is that any sequence of batch sizes ends with the wallet holding each stored entry
///      once and in order.
///
///      Entry counts stay modest because every entry is a real SSTORE into the wallet at roughly
///      50,000 gas, and the point is the arithmetic around the cursor rather than the volume.
contract LazyHistoryCopyTest is FuzzBase {

    /// @dev Enough runs to cross the cap boundary in both directions without the SSTOREs dominating
    uint256 private constant MAX_FUZZED_ENTRIES = 120;

    string private constant ESIM = "fuzz_esim";

    /// @notice Every stored entry reaches the wallet exactly once, whatever the batch size
    /// @dev This is the regression gate on the duplication the one-shot guard used to prevent. A
    ///      cursor that failed to advance, advanced twice, or was read after the write would show
    ///      up here as a wallet holding the wrong number of entries or the wrong ones.
    function testFuzz_setHistoryForLazyWallet_copiesEveryEntryExactlyOnce(
        uint256 _entries,
        uint256 _batch
    ) public {
        uint256 entries = bound(_entries, 1, MAX_FUZZED_ENTRIES);
        uint256 batch = bound(_batch, 1, lazyWalletRegistry.MAX_HISTORY_ENTRIES_PER_CALL());

        MockESIMWallet eSIMWallet = _lazyDeploy(entries);

        uint256 remaining = entries;
        while(remaining > 0) {
            vm.prank(eSIMWalletAdmin);
            (uint256 copied, uint256 left) = lazyWalletRegistry.setHistoryForLazyWallet(ESIM, batch);

            assertLe(copied, batch, "A call must never write more than it was asked for");
            assertEq(left, remaining - copied, "The remainder must account for what was just written");
            remaining = left;
        }

        DataBundleDetails[] memory stored = lazyWalletRegistry.getDeviceIdentifierToESIMDetails(
            customDeviceUniqueIdentifiers[0],
            ESIM
        );
        DataBundleDetails[] memory inWallet = eSIMWallet.getTransactionHistory();

        assertEq(inWallet.length, entries, "The wallet must hold every entry and no more");
        for(uint256 i=0; i<entries; ++i) {
            assertEq(inWallet[i].dataBundleID, stored[i].dataBundleID);
            assertEq(inWallet[i].dataBundlePrice, stored[i].dataBundlePrice);
        }
        assertEq(lazyWalletRegistry.historyEntriesCopied(ESIM), entries, "The cursor must end at the length");
    }

    /// @notice A finished copy stays finished, whatever batch size the next call asks for
    /// @dev The terminal condition is what a caller loops against, so it has to hold for every
    ///      valid batch size rather than only the one that finished the copy.
    function testFuzz_setHistoryForLazyWallet_staysFinished(uint256 _batch) public {
        uint256 batch = bound(_batch, 1, lazyWalletRegistry.MAX_HISTORY_ENTRIES_PER_CALL());

        MockESIMWallet eSIMWallet = _lazyDeploy(3);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.setHistoryForLazyWallet(ESIM, 50);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.HistoryAlreadyCopied.selector, ESIM));
        lazyWalletRegistry.setHistoryForLazyWallet(ESIM, batch);

        assertEq(eSIMWallet.getTransactionHistory().length, 3, "The refused call must not have written anything");
    }

    /// @notice A batch outside the accepted range is always refused
    /// @dev Zero and anything past the cap both revert. Clamping instead would let a caller believe
    ///      it had written more than it did and run its own position ahead of the cursor.
    function testFuzz_setHistoryForLazyWallet_refusesABatchOutsideTheRange(uint256 _batch) public {
        uint256 cap = lazyWalletRegistry.MAX_HISTORY_ENTRIES_PER_CALL();
        uint256 batch = bound(_batch, cap + 1, type(uint256).max);

        MockESIMWallet eSIMWallet = _lazyDeploy(2);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.TooManyHistoryEntries.selector, batch, cap));
        lazyWalletRegistry.setHistoryForLazyWallet(ESIM, batch);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.TooManyHistoryEntries.selector, 0, cap));
        lazyWalletRegistry.setHistoryForLazyWallet(ESIM, 0);

        assertEq(eSIMWallet.getTransactionHistory().length, 0, "A refused batch must not write anything");
    }

    /// @notice Binds one eSIM with the requested number of purchases and deploys its wallet
    function _lazyDeploy(uint256 _entries) private returns (MockESIMWallet) {
        string memory device = customDeviceUniqueIdentifiers[0];

        string[] memory devices = new string[](1);
        devices[0] = device;

        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = new string[](1);
        eSIMs[0][0] = ESIM;

        for(uint256 i=0; i<_entries; ++i) {
            DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);
            bundles[0] = new DataBundleDetails[](1);
            bundles[0][0] = DataBundleDetails(string.concat("DB_", vm.toString(i)), i + 1);

            vm.prank(eSIMWalletAdmin);
            lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, bundles);
        }

        vm.prank(eSIMWalletAdmin);
        (, address[] memory eSIMWallets) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            device,
            9001,
            0
        );

        return MockESIMWallet(payable(eSIMWallets[0]));
    }
}
