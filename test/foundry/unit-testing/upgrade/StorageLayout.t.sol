// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "test/utils/DeployerBase.sol";

/// @notice Pins the slot of every variable that sits behind a proxy.
/// @dev These contracts are all behind proxies that already hold state, so a slot number is part
///      of the deployment and not an implementation detail. Moving one breaks nothing at compile
///      time and fails no other test: the new code reads a slot the old code never wrote, so the
///      upgraded contract comes back up reading zero while the real value sits where it was left.
///
///      The way that happens by accident is a variable added to a base contract, because base
///      storage comes first. `Account4337` declares `owner` and `DeviceWallet` picks up at slot
///      2, so a single new variable in `Account4337` pushes `registry`, `eSIMWalletFactory`,
///      `deviceUniqueIdentifier`, `isValidESIMWallet` and `canPullETH` down on every device
///      wallet that exists. `RegistryHelper` sits under `Registry` the same way, which is what
///      the 50 slot gap at `RegistryHelper.sol:86` is holding open and why `Registry`'s own
///      state starts at slot 59 rather than slot 9.
///
///      Each check writes a sentinel into a slot and reads the variable back through its getter.
///      The getter is compiled against the current layout, so agreement means the variable still
///      resolves to the slot the deployment wrote. A trailing gap would not help any of this:
///      only `Account4337` and `RegistryHelper` are inherited, and everything else appends.
contract StorageLayoutTest is DeployerBase {

    address private constant SENTINEL = address(uint160(0xCAFEBABE));

    /// @notice Slot holding `_key`'s entry in the mapping declared at `_slot`.
    function _entry(address _key, uint256 _slot) private pure returns (bytes32) {
        return keccak256(abi.encode(_key, _slot));
    }

    /// @notice A short string as the single word Solidity packs it into: the bytes left aligned
    /// with twice the length in the low byte.
    function _shortString() private pure returns (bytes32) {
        return bytes32("pin") | bytes32(uint256(6));
    }

    function _deployDeviceWallet() private returns (MockDeviceWallet) {
        vm.prank(address(typeCastEntryPoint));
        address walletAddress = address(
            deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], pubKey1, 501)
        );

        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(walletAddress, customDeviceUniqueIdentifiers[0], pubKey1);

        return MockDeviceWallet(payable(walletAddress));
    }

    function test_layout_deviceWalletSlotsAreUnchanged() public {
        MockDeviceWallet wallet = _deployDeviceWallet();
        address target = address(wallet);

        // Declared by Account4337, and the reason a variable can never be appended to it
        vm.store(target, bytes32(uint256(0)), bytes32(uint256(0xA1)));
        vm.store(target, bytes32(uint256(1)), bytes32(uint256(0xA2)));
        assertEq(wallet.owner(0), bytes32(uint256(0xA1)), "Account4337.owner[0] must read slot 0");
        assertEq(wallet.owner(1), bytes32(uint256(0xA2)), "Account4337.owner[1] must read slot 1");

        _assertDeviceWalletOwnSlots(wallet, target);
    }

    /// @dev Split out of the test body because the assertions are cumulative on the stack.
    function _assertDeviceWalletOwnSlots(MockDeviceWallet _wallet, address _target) private {
        vm.store(_target, bytes32(uint256(2)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(address(_wallet.registry()), SENTINEL, "DeviceWallet.registry must read slot 2");

        vm.store(_target, bytes32(uint256(3)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(
            address(_wallet.eSIMWalletFactory()),
            SENTINEL,
            "DeviceWallet.eSIMWalletFactory must read slot 3"
        );

        vm.store(_target, bytes32(uint256(4)), _shortString());
        assertEq(_wallet.deviceUniqueIdentifier(), "pin", "DeviceWallet.deviceUniqueIdentifier must read slot 4");

        vm.store(_target, _entry(SENTINEL, 5), bytes32(uint256(1)));
        assertTrue(_wallet.isValidESIMWallet(SENTINEL), "DeviceWallet.isValidESIMWallet must read slot 5");

        vm.store(_target, _entry(SENTINEL, 6), bytes32(uint256(1)));
        assertTrue(_wallet.canPullETH(SENTINEL), "DeviceWallet.canPullETH must read slot 6");
    }

    function test_layout_eSIMWalletSlotsAreUnchanged() public {
        MockDeviceWallet deviceWallet = _deployDeviceWallet();

        vm.prank(address(deviceWallet));
        address target = eSIMWalletFactory.deployESIMWallet(address(deviceWallet), 502);
        MockESIMWallet wallet = MockESIMWallet(payable(target));

        vm.store(target, bytes32(uint256(0)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(wallet.eSIMWalletFactory(), SENTINEL, "ESIMWallet.eSIMWalletFactory must read slot 0");

        vm.store(target, bytes32(uint256(1)), _shortString());
        assertEq(wallet.eSIMUniqueIdentifier(), "pin", "ESIMWallet.eSIMUniqueIdentifier must read slot 1");

        vm.store(target, bytes32(uint256(2)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(address(wallet.deviceWallet()), SENTINEL, "ESIMWallet.deviceWallet must read slot 2");

        _assertESIMWalletTailSlots(wallet, target);
    }

    /// @dev Split out of the test body because the assertions are cumulative on the stack.
    function _assertESIMWalletTailSlots(MockESIMWallet _wallet, address _target) private {
        // One entry long, with a price written straight into the element the length implies
        vm.store(_target, bytes32(uint256(3)), bytes32(uint256(1)));
        vm.store(_target, bytes32(uint256(keccak256(abi.encode(uint256(3)))) + 1), bytes32(uint256(0xB1)));
        (, uint256 price) = _wallet.transactionHistory(0);
        assertEq(price, 0xB1, "ESIMWallet.transactionHistory must read slot 3");

        vm.store(_target, bytes32(uint256(4)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(_wallet.newRequestedOwner(), SENTINEL, "ESIMWallet.newRequestedOwner must read slot 4");
    }

    function test_layout_registrySlotsAreUnchanged() public {
        address target = address(registry);

        vm.store(target, bytes32(uint256(0)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(registry.lazyWalletRegistry(), SENTINEL, "RegistryHelper.lazyWalletRegistry must read slot 0");

        vm.store(target, bytes32(uint256(1)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(
            address(registry.deviceWalletFactory()),
            SENTINEL,
            "RegistryHelper.deviceWalletFactory must read slot 1"
        );

        _assertRegistryHelperMappingSlots(target);
        _assertRegistryOwnSlots(target);
    }

    /// @dev Split out of the test body because the assertions are cumulative on the stack.
    function _assertRegistryHelperMappingSlots(address _target) private {
        vm.store(_target, bytes32(uint256(2)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(
            address(registry.eSIMWalletFactory()),
            SENTINEL,
            "RegistryHelper.eSIMWalletFactory must read slot 2"
        );

        vm.store(_target, _entry(SENTINEL, 4), bytes32(uint256(0xC1)));
        assertEq(
            registry.deviceWalletToOwner(SENTINEL, 0),
            bytes32(uint256(0xC1)),
            "RegistryHelper.deviceWalletToOwner must read slot 4"
        );

        vm.store(_target, _entry(SENTINEL, 6), bytes32(uint256(1)));
        assertTrue(registry.isDeviceWalletValid(SENTINEL), "RegistryHelper.isDeviceWalletValid must read slot 6");

        vm.store(_target, _entry(SENTINEL, 7), bytes32(uint256(uint160(SENTINEL))));
        assertEq(
            registry.isESIMWalletValid(SENTINEL),
            SENTINEL,
            "RegistryHelper.isESIMWalletValid must read slot 7"
        );

        vm.store(_target, _entry(SENTINEL, 8), bytes32(uint256(1)));
        assertTrue(
            registry.isESIMWalletOnStandby(SENTINEL),
            "RegistryHelper.isESIMWalletOnStandby must read slot 8"
        );
    }

    /// @notice Registry's own state starts at slot 59, immediately after RegistryHelper's 50 slot
    /// gap. These five are what that gap is protecting, and they move if it is ever resized.
    function _assertRegistryOwnSlots(address _target) private {
        vm.store(_target, bytes32(uint256(59)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(address(registry.entryPoint()), SENTINEL, "Registry.entryPoint must read slot 59");

        vm.store(_target, bytes32(uint256(60)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(registry.eSIMWalletAdmin(), SENTINEL, "Registry.eSIMWalletAdmin must read slot 60");

        vm.store(_target, bytes32(uint256(61)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(registry.vault(), SENTINEL, "Registry.vault must read slot 61");

        _assertRegistryLastSlots(_target);
    }

    /// @dev Split out because the assertions are cumulative on the stack.
    function _assertRegistryLastSlots(address _target) private {
        // Slot 62 is a reserved placeholder. No getter reads it, so it is pinned by loading it
        // directly, and `upgradeManager()` has to stay indifferent to whatever it holds.
        vm.store(_target, bytes32(uint256(62)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(
            address(uint160(uint256(vm.load(_target, bytes32(uint256(62)))))),
            SENTINEL,
            "Registry slot 62 must still be reserved"
        );
        assertEq(registry.upgradeManager(), registry.owner(), "Registry.upgradeManager must not read slot 62");

        vm.store(_target, bytes32(uint256(63)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(registry.newRequestedAdmin(), SENTINEL, "Registry.newRequestedAdmin must read slot 63");
    }

    function test_layout_lazyWalletRegistrySlotsAreUnchanged() public {
        address target = address(lazyWalletRegistry);

        // Slot 0 is a reserved placeholder. No getter reads it, so it is pinned by loading it
        // directly, and `upgradeManager()` has to stay indifferent to whatever it holds.
        vm.store(target, bytes32(uint256(0)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(
            address(uint160(uint256(vm.load(target, bytes32(uint256(0)))))),
            SENTINEL,
            "LazyWalletRegistry slot 0 must still be reserved"
        );
        assertEq(
            lazyWalletRegistry.upgradeManager(),
            lazyWalletRegistry.owner(),
            "LazyWalletRegistry.upgradeManager must not read slot 0"
        );

        vm.store(target, bytes32(uint256(1)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(address(lazyWalletRegistry.registry()), SENTINEL, "LazyWalletRegistry.registry must read slot 1");

        _assertLazyWalletRegistryMappingSlots(target);
    }

    /// @notice Pins the mapping slots, including the two the batched history copy added
    /// @dev A mapping entry sits at keccak256(key . slot), so writing that word and reading the
    ///      getter back proves which slot the mapping occupies. The cursor and the wallet record
    ///      were appended, and an insertion anywhere above them moves both, which would leave the
    ///      copy reading a cursor of zero and writing history into whatever address it found.
    function _assertLazyWalletRegistryMappingSlots(address _target) private {
        string memory key = "pin";

        vm.store(_target, keccak256(abi.encodePacked(bytes(key), uint256(3))), bytes32(bytes("pinned")) | bytes32(uint256(12)));
        assertEq(
            lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(key),
            "pinned",
            "LazyWalletRegistry.eSIMIdentifierToDeviceIdentifier must read slot 3"
        );

        vm.store(_target, keccak256(abi.encodePacked(bytes(key), uint256(5))), bytes32(uint256(0xB2)));
        assertEq(
            lazyWalletRegistry.historyEntriesCopied(key),
            0xB2,
            "LazyWalletRegistry.historyEntriesCopied must read slot 5"
        );

        vm.store(_target, keccak256(abi.encodePacked(bytes(key), uint256(6))), bytes32(uint256(uint160(SENTINEL))));
        assertEq(
            lazyWalletRegistry.lazyDeployedESIMWallet(key),
            SENTINEL,
            "LazyWalletRegistry.lazyDeployedESIMWallet must read slot 6"
        );
    }

    function test_layout_deviceWalletFactorySlotsAreUnchanged() public {
        address target = address(deviceWalletFactory);

        vm.store(target, bytes32(uint256(0)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(address(deviceWalletFactory.beacon()), SENTINEL, "DeviceWalletFactory.beacon must read slot 0");

        vm.store(target, bytes32(uint256(1)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(
            address(deviceWalletFactory.entryPoint()),
            SENTINEL,
            "DeviceWalletFactory.entryPoint must read slot 1"
        );

        vm.store(target, bytes32(uint256(2)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(address(deviceWalletFactory.verifier()), SENTINEL, "DeviceWalletFactory.verifier must read slot 2");

        _assertDeviceWalletFactoryTailSlots(target);
    }

    /// @dev Split out of the test body because the assertions are cumulative on the stack.
    function _assertDeviceWalletFactoryTailSlots(address _target) private {
        vm.store(_target, bytes32(uint256(3)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(address(deviceWalletFactory.registry()), SENTINEL, "DeviceWalletFactory.registry must read slot 3");

        vm.store(_target, bytes32(uint256(4)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(
            address(deviceWalletFactory.eSIMWalletFactory()),
            SENTINEL,
            "DeviceWalletFactory.eSIMWalletFactory must read slot 4"
        );

        vm.store(_target, bytes32(uint256(5)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(deviceWalletFactory.vault(), SENTINEL, "DeviceWalletFactory.vault must read slot 5");

        vm.store(_target, _entry(SENTINEL, 6), bytes32(uint256(1)));
        assertTrue(
            deviceWalletFactory.deviceWalletInfoAdded(SENTINEL),
            "DeviceWalletFactory.deviceWalletInfoAdded must read slot 6"
        );
    }

    function test_layout_eSIMWalletFactorySlotsAreUnchanged() public {
        address target = address(eSIMWalletFactory);

        vm.store(target, bytes32(uint256(0)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(address(eSIMWalletFactory.registry()), SENTINEL, "ESIMWalletFactory.registry must read slot 0");

        vm.store(target, bytes32(uint256(1)), bytes32(uint256(uint160(SENTINEL))));
        assertEq(address(eSIMWalletFactory.beacon()), SENTINEL, "ESIMWalletFactory.beacon must read slot 1");

        vm.store(target, _entry(SENTINEL, 2), bytes32(uint256(1)));
        assertTrue(
            eSIMWalletFactory.isESIMWalletDeployed(SENTINEL),
            "ESIMWalletFactory.isESIMWalletDeployed must read slot 2"
        );
    }
}
