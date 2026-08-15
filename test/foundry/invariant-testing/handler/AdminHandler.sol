// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/CustomStructs.sol";
import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";
import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";

import {HandlerBase, HandlerConfig} from "test/foundry/invariant-testing/handler/HandlerBase.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Everything the eSIM wallet admin is allowed to do.
/// @dev The widest actor in the protocol by a distance. It deploys wallets on a user's behalf,
///      records purchase history before any wallet exists, moves an eSIM between devices while it
///      is still only a record, and charges a wallet for a data bundle. Most of what the campaign
///      is checking is whether that reach stops where the contracts say it stops.
contract AdminHandler is HandlerBase {

    constructor(HandlerConfig memory config) HandlerBase(config) {}

    /// @notice The admin deploys a batch of device wallets, each with one eSIM wallet
    /// @param count How many wallets the batch asks for
    /// @param seed Drives the identifiers, owner keys and salts
    /// @param deposit Total ETH offered for the batch, which may be less than the deposits ask for
    /// @param contest Whether to draw identifiers from the pool the lazy route also uses
    function deployDeviceWalletBatch(uint256 count, uint256 seed, uint256 deposit, bool contest)
        external
        counted
    {
        count = bound(count, 1, 3);
        deposit = bound(deposit, 0, _spendable(_currentAdmin(), 10 ether));

        string[] memory identifiers = new string[](count);
        bytes32[2][] memory ownerKeys = new bytes32[2][](count);
        uint256[] memory salts = new uint256[](count);
        uint256[] memory deposits = new uint256[](count);

        uint256 perWallet = deposit / count;
        for (uint256 i = 0; i < count; ++i) {
            identifiers[i] = contest
                ? _contestedDeviceIdentifier(seed + i)
                : _identifier(seed + i);
            ownerKeys[i] = _ownerKey(seed + i);
            salts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 0, 1000);
            deposits[i] = perWallet;
        }

        vm.prank(_currentAdmin());
        try deviceWalletFactory.deployDeviceWalletForUsers{value: deposit}(
            identifiers, ownerKeys, salts, deposits
        ) returns (Wallets[] memory deployed) {
            for (uint256 i = 0; i < deployed.length; ++i) {
                state.recordDeviceWallet(deployed[i].deviceWallet, identifiers[i], ownerKeys[i]);
                state.recordESIMWallet(deployed[i].eSIMWallet, deployed[i].deviceWallet);
            }
            state.recordCall("deployDeviceWalletBatch");
        } catch {
            state.recordRevert("deployDeviceWalletBatch");
        }
    }

    /// @notice The admin binds a wallet the permissionless path left unregistered
    /// @param index Which pending wallet to bind
    function postCreateAccount(uint256 index) external counted {
        uint256 pending = state.unregisteredCount();
        if (pending == 0) {
            state.recordRevert("postCreateAccount");
            return;
        }
        index = bound(index, 0, pending - 1);

        address wallet = state.unregisteredDeviceWallets(index);
        string memory identifier = state.unregisteredIdentifiers(index);
        bytes32[2] memory ownerKey = [
            state.unregisteredOwnerKeys(index, 0),
            state.unregisteredOwnerKeys(index, 1)
        ];
        uint256 salt = state.unregisteredSalts(index);

        vm.prank(_currentAdmin());
        try deviceWalletFactory.postCreateAccount(wallet, identifier, ownerKey, salt) {
            state.recordDeviceWallet(wallet, identifier, ownerKey);
            state.removePending(index);
            state.recordCall("postCreateAccount");
        } catch {
            state.recordRevert("postCreateAccount");
        }
    }

    /// @notice The admin adds another eSIM wallet to a device wallet that already exists
    /// @dev The ETH access flag is not drawn. False is its only valid value, so a fuzzed one would
    ///      revert half the time and the action would never reach its share of the distribution.
    /// @param deviceIndex Which device wallet gets the new eSIM wallet
    /// @param salt CREATE2 salt, kept small so collisions are reached rather than assumed away
    function deployESIMWalletForDevice(uint256 deviceIndex, uint256 salt)
        external
        counted
    {
        address device = _pickDeviceWallet(deviceIndex);
        if (device == address(0)) {
            state.recordRevert("deployESIMWalletForDevice");
            return;
        }
        salt = bound(salt, 0, 1000);

        vm.prank(_currentAdmin());
        try DeviceWallet(payable(device)).deployESIMWallet(false, salt) returns (
            address wallet
        ) {
            state.recordESIMWallet(wallet, device);
            state.clearETHAccessGrant(device, wallet);
            state.recordCall("deployESIMWalletForDevice");
        } catch {
            state.recordRevert("deployESIMWalletForDevice");
        }
    }

    /// @notice The admin writes an eSIM identifier onto a wallet deployed the ordinary way
    /// @dev The lazy route sets its identifiers inside the deployment, so without this the campaign
    ///      only ever saw one of the two paths that claim one. The contested pool is what makes the
    ///      two collide.
    /// @param eSIMIndex Where the scan for an unnamed wallet starts
    /// @param seed Drives the identifier
    /// @param contest Whether to draw the identifier from the pool the lazy route also uses
    function setESIMIdentifier(uint256 eSIMIndex, uint256 seed, bool contest) external counted {
        (address wallet, address device) = _pickUnnamedESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("setESIMIdentifier");
            return;
        }

        string memory identifier = contest
            ? _contestedESIMIdentifier(seed)
            : _ordinaryESIMIdentifier(seed);

        vm.prank(_currentAdmin());
        try DeviceWallet(payable(device)).setESIMUniqueIdentifierForAnESIMWallet(wallet, identifier) returns (
            string memory
        ) {
            state.recordCall("setESIMIdentifier");
        } catch {
            state.recordRevert("setESIMIdentifier");
        }
    }

    /// @notice The admin charges an eSIM wallet for a data bundle
    /// @dev The price is unbounded upward on purpose. The ceiling is the only thing standing
    ///      between the admin and a wallet's whole balance, so a run has to reach past it.
    /// @param eSIMIndex Which eSIM wallet pays
    /// @param price What it is charged
    function buyDataBundle(uint256 eSIMIndex, uint256 price) external counted {
        address wallet = _pickESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("buyDataBundle");
            return;
        }
        price = bound(price, 1, 100 ether);

        address device = registry.isESIMWalletValid(wallet);
        uint256 vaultBefore = vault.balance;
        uint256 walletsBefore = wallet.balance + device.balance;
        uint256 historyBefore = MockESIMWallet(payable(wallet)).getTransactionHistory().length;

        vm.prank(_currentAdmin());
        try ESIMWallet(payable(wallet)).buyDataBundle(
            DataBundleDetails({dataBundleID: "bundle", dataBundlePrice: price})
        ) {
            // Asserted here rather than as an invariant because the ceiling is a property of the
            // charge and not of any state left behind. Both ceilings move during a run, so a
            // purchase that was inside the ceiling when it went through can sit above the one the
            // next invariant call would read
            uint256 cap = ESIMWallet(payable(wallet)).dataBundlePriceCap();
            if (cap == 0) cap = registry.defaultDataBundlePriceCap();
            if (cap != 0) {
                assertLe(price, cap, "A purchase went through above the ceiling that applied to it");
            }

            // The wallet pays out of its own balance and pulls the shortfall from the device
            // wallet, so neither balance alone says what a purchase cost. Their sum does, and it
            // has to fall by exactly what the vault gained
            assertEq(
                vault.balance - vaultBefore, price, "The vault received something other than the price"
            );
            assertEq(
                walletsBefore - (wallet.balance + device.balance),
                price,
                "A purchase moved a different amount out of the wallets than it sent to the vault"
            );
            assertEq(
                MockESIMWallet(payable(wallet)).getTransactionHistory().length,
                historyBefore + 1,
                "A purchase did not leave exactly one entry behind"
            );

            state.recordCall("buyDataBundle");
        } catch {
            state.recordRevert("buyDataBundle");
        }
    }

    /// @notice The admin records purchase history against a device identifier with no wallet yet
    /// @dev The reuse branch presents an identifier that already carries history. That is two
    ///      guards in one: appending to a device still waiting to be deployed has to work, and
    ///      appending to one that has since been deployed has to be refused.
    /// @param seed Drives the device and eSIM identifiers
    /// @param eSIMCount How many eSIM identifiers the batch carries
    /// @param reuseDevice Whether to present an identifier that already has history
    /// @param contest Whether to draw identifiers from the pool the ordinary route also uses
    function populateLazyHistory(uint256 seed, uint256 eSIMCount, bool reuseDevice, bool contest)
        external
        counted
    {
        eSIMCount = bound(eSIMCount, 1, 3);

        uint256 lazyDevices = state.lazyDeviceIdentifierCount();
        // The contested pool already forces reuse, so `reuseDevice` has nothing left to add there
        string memory deviceIdentifier = contest
            ? _contestedDeviceIdentifier(seed)
            : reuseDevice && lazyDevices > 0
                ? state.lazyDeviceIdentifiers(seed % lazyDevices)
                : _lazyIdentifier(seed);

        string[] memory deviceIdentifiers = new string[](1);
        deviceIdentifiers[0] = deviceIdentifier;

        string[][] memory eSIMIdentifiers = new string[][](1);
        eSIMIdentifiers[0] = new string[](eSIMCount);

        DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);
        bundles[0] = new DataBundleDetails[](eSIMCount);

        for (uint256 i = 0; i < eSIMCount; ++i) {
            eSIMIdentifiers[0][i] = contest
                ? _contestedESIMIdentifier(seed + i)
                : _eSIMIdentifier(seed + i);
            bundles[0][i] = DataBundleDetails({dataBundleID: "bundle", dataBundlePrice: 1 gwei});
        }

        vm.prank(_currentAdmin());
        try lazyWalletRegistry.batchPopulateHistory(deviceIdentifiers, eSIMIdentifiers, bundles) {
            state.recordLazyDevice(deviceIdentifier);
            for (uint256 i = 0; i < eSIMCount; ++i) {
                state.recordLazyESIM(eSIMIdentifiers[0][i], deviceIdentifier);
            }
            state.recordCall("populateLazyHistory");
        } catch {
            state.recordRevert("populateLazyHistory");
        }
    }

    /// @notice The admin turns a device identifier's recorded history into real wallets
    /// @dev The owner key comes from the identifier rather than from the fuzzer, so a retry after
    ///      a failed deploy presents the same key the first attempt did. A fresh key each time
    ///      would make every retry look like a new device and hide the redeploy guard.
    /// @param index Which populated device identifier to deploy
    /// @param salt CREATE2 salt, kept small so collisions are reached
    /// @param deposit ETH to seed the new device wallet with
    /// @param maxWallets Batch size, swept past the cap so refusals are exercised too
    function deployLazyWallet(uint256 index, uint256 salt, uint256 deposit, uint256 maxWallets) external counted {
        uint256 lazyDevices = state.lazyDeviceIdentifierCount();
        if (lazyDevices == 0) {
            state.recordRevert("deployLazyWallet");
            return;
        }
        string memory deviceIdentifier = state.lazyDeviceIdentifiers(bound(index, 0, lazyDevices - 1));
        salt = bound(salt, 0, 1000);
        deposit = bound(deposit, 0, _spendable(_currentAdmin(), 5 ether));
        maxWallets = bound(maxWallets, 0, lazyWalletRegistry.MAX_ESIM_WALLETS_PER_CALL() + 5);

        bytes32[2] memory ownerKey = _ownerKey(uint256(keccak256(bytes(deviceIdentifier))));

        vm.prank(_currentAdmin());
        try lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier{value: deposit}(
            ownerKey, deviceIdentifier, salt, deposit, maxWallets
        ) returns (address device, address[] memory wallets, uint256) {
            state.recordDeviceWallet(device, deviceIdentifier, ownerKey);
            for (uint256 i = 0; i < wallets.length; ++i) {
                state.recordESIMWallet(wallets[i], device);
            }
            state.recordCall("deployLazyWallet");
        } catch {
            state.recordRevert("deployLazyWallet");
        }
    }

    /// @notice The admin deploys the next batch of eSIM wallets for a device already set up
    /// @dev Reached only after `deployLazyWallet` left something outstanding, which a small batch
    ///      size makes common. Without this the campaign would only ever see devices deployed whole,
    ///      and the half-deployed state is the one the batching introduces.
    /// @param index Which populated device identifier to continue
    /// @param maxWallets Batch size, swept past the cap so refusals are exercised too
    function deployMoreLazyESIMWallets(uint256 index, uint256 maxWallets) external counted {
        uint256 lazyDevices = state.lazyDeviceIdentifierCount();
        if (lazyDevices == 0) {
            state.recordRevert("deployMoreLazyESIMWallets");
            return;
        }
        string memory deviceIdentifier = state.lazyDeviceIdentifiers(bound(index, 0, lazyDevices - 1));
        maxWallets = bound(maxWallets, 0, lazyWalletRegistry.MAX_ESIM_WALLETS_PER_CALL() + 5);

        address device = registry.uniqueIdentifierToDeviceWallet(deviceIdentifier);

        vm.prank(_currentAdmin());
        try lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(
            deviceIdentifier, maxWallets
        ) returns (address[] memory wallets, uint256) {
            for (uint256 i = 0; i < wallets.length; ++i) {
                state.recordESIMWallet(wallets[i], device);
            }
            state.recordCall("deployMoreLazyESIMWallets");
        } catch {
            state.recordRevert("deployMoreLazyESIMWallets");
        }
    }

    /// @notice The admin copies the next batch of an eSIM's recorded history into its wallet
    /// @dev Deployment no longer carries history, so this is the only path that puts it in a
    ///      wallet. The batch size is fuzzed across the whole accepted range and past it, since the
    ///      cursor arithmetic is what stops entries being written twice.
    /// @param eSIMIndex Which bound eSIM identifier to copy for
    /// @param maxEntries Batch size, swept past the cap so refusals are exercised too
    function copyLazyHistory(uint256 eSIMIndex, uint256 maxEntries) external counted {
        uint256 lazyESIMs = state.lazyESIMIdentifierCount();
        if (lazyESIMs == 0) {
            state.recordRevert("copyLazyHistory");
            return;
        }

        string memory eSIMIdentifier = state.lazyESIMIdentifiers(bound(eSIMIndex, 0, lazyESIMs - 1));
        maxEntries = bound(maxEntries, 0, lazyWalletRegistry.MAX_HISTORY_ENTRIES_PER_CALL() + 5);

        vm.prank(_currentAdmin());
        try lazyWalletRegistry.setHistoryForLazyWallet(eSIMIdentifier, maxEntries) {
            state.recordCall("copyLazyHistory");
        } catch {
            state.recordRevert("copyLazyHistory");
        }
    }

    /// @notice The admin moves an eSIM identifier to a different device identifier
    /// @dev Only reachable while neither side has been deployed. Pointing it at an identifier that
    ///      has a wallet is the case that would orphan an eSIM, so the run presents that too.
    /// @param eSIMIndex Which eSIM identifier to move
    /// @param seed Drives the destination identifier
    /// @param toExistingDevice Whether to move it onto an identifier that already has history
    function switchESIMIdentifier(uint256 eSIMIndex, uint256 seed, bool toExistingDevice)
        external
        counted
    {
        uint256 lazyESIMs = state.lazyESIMIdentifierCount();
        if (lazyESIMs == 0) {
            state.recordRevert("switchESIMIdentifier");
            return;
        }
        string memory eSIMIdentifier = state.lazyESIMIdentifiers(bound(eSIMIndex, 0, lazyESIMs - 1));
        string memory oldDevice = state.ghost_eSIMIdentifierToDeviceIdentifier(eSIMIdentifier);

        uint256 lazyDevices = state.lazyDeviceIdentifierCount();
        string memory newDevice = toExistingDevice && lazyDevices > 0
            ? state.lazyDeviceIdentifiers(seed % lazyDevices)
            : _lazyIdentifier(seed);

        vm.prank(_currentAdmin());
        try lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier(
            eSIMIdentifier, oldDevice, newDevice
        ) returns (bool) {
            state.recordLazyESIM(eSIMIdentifier, newDevice);
            state.recordLazyDevice(newDevice);
            state.recordCall("switchESIMIdentifier");
        } catch {
            state.recordRevert("switchESIMIdentifier");
        }
    }

    /// @notice The admin stops every ETH-moving path in the protocol
    /// @dev Tripped on a quarter of the calls rather than all of them. Pause and release are one
    ///      entry point each and the runner picks between them evenly, so an unconditional pause
    ///      would leave the protocol halted for about half the sequence and take the ETH paths
    ///      down with it. A quarter still trips several times in a five hundred call run.
    /// @param seed Decides whether this call is one of the ones that trips it
    function pauseProtocol(uint256 seed) external counted {
        if (seed % 4 != 0) {
            state.recordRevert("pauseProtocol");
            return;
        }

        vm.prank(_currentAdmin());
        try registry.pause() {
            state.recordCall("pauseProtocol");
        } catch {
            state.recordRevert("pauseProtocol");
        }
    }

    /// @notice The nominated successor takes the admin role
    function acceptAdminUpdate() external counted {
        address nominee = registry.newRequestedAdmin();
        if (nominee == address(0)) {
            state.recordRevert("acceptAdminUpdate");
            return;
        }

        vm.prank(nominee);
        try registry.acceptAdminUpdate() returns (address) {
            state.recordCall("acceptAdminUpdate");
        } catch {
            state.recordRevert("acceptAdminUpdate");
        }
    }
}
