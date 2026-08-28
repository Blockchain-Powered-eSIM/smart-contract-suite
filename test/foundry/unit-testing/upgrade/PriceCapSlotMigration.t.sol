// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import "test/utils/DeployerBase.sol";

/// @notice What the deployed proxies read after the cents change, and why the upgrade needs two
///         transactions behind it.
/// @dev The price ceiling moved from its own slot to eight bytes packed above an address, on both
///      the registry and the eSIM wallet, and the registry's old ceiling slot is now the payment
///      adapter pointer. Neither move breaks a compile and neither fails any other test, because
///      every test starts from a proxy this code initialised. A proxy the old code initialised is
///      the case nothing else covers, and the tests below are that case.
///
///      Each one writes the slot the way the old deployment left it and reads back through the new
///      getters. They pass by asserting what the protocol actually does, not what it should do, so
///      they are a record of the migration that is owed rather than a check that it happened.
contract PriceCapSlotMigrationTest is DeployerBase {

    /// @dev Registry slot 64 packs `newRequestedAdmin`, `paused`, `adminDisabled` and the ceiling.
    uint256 private constant REGISTRY_PACKED_SLOT = 64;

    /// @dev Held the old ceiling in wei. Holds the payment adapter pointer now.
    uint256 private constant REGISTRY_ADAPTER_SLOT = 65;

    /// @dev eSIM wallet slot 4 packs `newRequestedOwner` and the wallet's own ceiling.
    uint256 private constant WALLET_PACKED_SLOT = 4;

    /// @dev What a deployed registry holds in slot 65: a ceiling of 0.05 ETH in wei.
    uint256 private constant OLD_CAP_IN_WEI = 0.05 ether;

    DeviceWallet private deviceWallet;
    MockESIMWallet private eSIMWallet;

    function _deployWallets() private {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);

        identifiers[0] = customDeviceUniqueIdentifiers[0];
        keys[0] = pubKey1;
        salts[0] = 7300;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets =
            deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, new uint256[](1));

        deviceWallet = DeviceWallet(payable(wallets[0].deviceWallet));
        eSIMWallet = MockESIMWallet(payable(wallets[0].eSIMWallet));

        vm.deal(address(deviceWallet), 100 ether);
        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(address(eSIMWallet), true);
    }

    /// @notice Clears the eight ceiling bytes and leaves the rest of the slot alone
    /// @dev The old code never wrote them, so on a deployed proxy they are zero whatever else the
    ///      slot holds.
    function _clearCeilingBytes(address _target, uint256 _slot, uint256 _bitOffset) private {
        uint256 word = uint256(vm.load(_target, bytes32(_slot)));
        vm.store(_target, bytes32(_slot), bytes32(word & ~(uint256(type(uint64).max) << _bitOffset)));
    }

    // ---------------------------------------------------------------------------------------------
    // The ceiling
    // ---------------------------------------------------------------------------------------------

    /// @notice Both ceilings read zero on a proxy the old code initialised
    /// @dev The registry's moved into slot 64 and the wallet's into slot 4, in bytes neither
    ///      contract ever wrote before, so both come back as a slot that was never set.
    function test_migration_bothCeilingsReadZero() public {
        _deployWallets();

        _clearCeilingBytes(address(registry), REGISTRY_PACKED_SLOT, 176);
        _clearCeilingBytes(address(eSIMWallet), WALLET_PACKED_SLOT, 160);

        assertEq(registry.defaultPriceCapUSDCents(), 0, "The registry ceiling is not carried over");
        assertEq(eSIMWallet.priceCapUSDCents(), 0, "The wallet ceiling is not carried over");
    }

    /// @notice Two zero ceilings mean no ceiling, not a ceiling of zero
    /// @dev Zero on the wallet hands the decision to the registry and zero on the registry means
    ///      unlimited, so an upgraded deployment accepts any price until someone calls
    ///      `setDefaultPriceCapUSDCents`. That call is the migration, and this is what it costs to
    ///      skip it.
    function test_migration_anUnsetCeilingAcceptsAnyPrice() public {
        _deployWallets();

        _clearCeilingBytes(address(registry), REGISTRY_PACKED_SLOT, 176);
        _clearCeilingBytes(address(eSIMWallet), WALLET_PACKED_SLOT, 160);

        vm.prank(eSIMWalletAdmin);
        eSIMWallet.buyDataBundle(bundle("DB_UNCAPPED", type(uint64).max), 1 ether, nextRef());

        (, uint64 recorded,) = eSIMWallet.transactionHistory(0);
        assertEq(recorded, type(uint64).max, "A price of $184 quadrillion was recorded with no ceiling set");
    }

    /// @notice Setting the registry ceiling is enough to close it again
    /// @dev Every wallet reads the registry when its own is zero, so one owner call covers the
    ///      whole deployment and no per-wallet transaction is needed.
    function test_migration_settingTheRegistryCeilingCoversEveryWallet() public {
        _deployWallets();

        _clearCeilingBytes(address(registry), REGISTRY_PACKED_SLOT, 176);
        _clearCeilingBytes(address(eSIMWallet), WALLET_PACKED_SLOT, 160);

        vm.prank(upgradeManager);
        registry.setDefaultPriceCapUSDCents(defaultPriceCapUSDCents);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DataBundlePriceAboveCap.selector, type(uint64).max, defaultPriceCapUSDCents
            )
        );
        eSIMWallet.buyDataBundle(bundle("DB_UNCAPPED", type(uint64).max), 1 ether, nextRef());
    }

    // ---------------------------------------------------------------------------------------------
    // The adapter pointer
    // ---------------------------------------------------------------------------------------------

    /// @notice The old ceiling slot is read as the payment adapter
    /// @dev Slot 65 held a ceiling in wei and now holds an address, so a deployed registry comes up
    ///      pointing at the low twenty bytes of whatever that number was.
    function test_migration_theOldCeilingSlotIsReadAsTheAdapter() public {
        vm.store(address(registry), bytes32(REGISTRY_ADAPTER_SLOT), bytes32(OLD_CAP_IN_WEI));

        assertEq(
            registry.paymentAdapter(),
            address(uint160(OLD_CAP_IN_WEI)),
            "The leftover ceiling is read as an address"
        );
    }

    /// @notice A leftover ceiling defeats the guard that would have caught it
    /// @dev `PaymentAdapterNotSet` only fires on a zero pointer. A non-zero one that holds no code
    ///      gets called instead, so every purchase reverts with nothing to say why until the owner
    ///      calls `setPaymentAdapter`.
    function test_migration_aLeftoverCeilingHidesThePaymentAdapterNotSetError() public {
        _deployWallets();
        vm.store(address(registry), bytes32(REGISTRY_ADAPTER_SLOT), bytes32(OLD_CAP_IN_WEI));

        assertEq(address(uint160(OLD_CAP_IN_WEI)).code.length, 0, "The leftover address holds no code");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert();
        registry.recordSettledPurchase(
            address(eSIMWallet),
            bundle("DB_STRANDED", TEST_PRICE_CENTS),
            ASSET_USDC,
            0,
            nextRef()
        );
    }

    /// @notice Pointing the registry at the adapter clears it
    /// @dev The pointer is not write-once, so the leftover is recoverable with one owner call.
    function test_migration_settingTheAdapterRecoversFromTheLeftover() public {
        _deployWallets();
        vm.store(address(registry), bytes32(REGISTRY_ADAPTER_SLOT), bytes32(OLD_CAP_IN_WEI));

        vm.prank(upgradeManager);
        registry.setPaymentAdapter(address(paymentAdapter));

        vm.prank(eSIMWalletAdmin);
        registry.recordSettledPurchase(
            address(eSIMWallet),
            bundle("DB_RECOVERED", TEST_PRICE_CENTS),
            ASSET_USDC,
            0,
            nextRef()
        );

        assertEq(eSIMWallet.getTransactionHistory().length, 1, "The purchase is recorded once the pointer is right");
    }
}
