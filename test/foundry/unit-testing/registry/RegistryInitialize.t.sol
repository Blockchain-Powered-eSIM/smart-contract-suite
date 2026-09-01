// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "test/utils/DeployerBase.sol";

contract RegistryInitializeTest is DeployerBase {

    /// @notice A zero device wallet factory is rejected at initialization
    /// @dev Neither factory has a setter, so accepting a zero would brick the registry for good.
    function test_initialize_revertsWhenDeviceWalletFactoryIsZero() public {
        MockRegistry registryImpl = new MockRegistry();

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_deviceWalletFactory"));
        new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                registryImpl.initialize,
                (
                    eSIMWalletAdmin,
                    vault,
                    upgradeManager,
                    address(0),
                    address(eSIMWalletFactory),
                    typeCastEntryPoint,
                    defaultPriceCapUSDCents
                )
            )
        );
    }

    /// @notice A zero eSIM wallet factory is rejected at initialization
    function test_initialize_revertsWhenESIMWalletFactoryIsZero() public {
        MockRegistry registryImpl = new MockRegistry();

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_eSIMWalletFactory"));
        new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                registryImpl.initialize,
                (
                    eSIMWalletAdmin,
                    vault,
                    upgradeManager,
                    address(deviceWalletFactory),
                    address(0),
                    typeCastEntryPoint,
                    defaultPriceCapUSDCents
                )
            )
        );
    }

    /// @notice A zero vault is rejected at initialization
    /// @dev This is the address every data bundle payment lands on, and the setter refuses zero, so
    ///      the only way one could get in is here.
    function test_initialize_revertsWhenVaultIsZero() public {
        MockRegistry registryImpl = new MockRegistry();

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_vault"));
        new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                registryImpl.initialize,
                (
                    eSIMWalletAdmin,
                    address(0),
                    upgradeManager,
                    address(deviceWalletFactory),
                    address(eSIMWalletFactory),
                    typeCastEntryPoint,
                    defaultPriceCapUSDCents
                )
            )
        );
    }

    /// @notice A zero price cap is rejected at initialization
    /// @dev A zero cap, wallet-level or registry-level, reads as "no ceiling" in
    ///      `ESIMWallet._requirePriceWithinCap`. Refusing it here is what guarantees the registry
    ///      default is always a real ceiling.
    function test_initialize_revertsWhenPriceCapIsZero() public {
        MockRegistry registryImpl = new MockRegistry();

        vm.expectRevert(Errors.ZeroDataBundlePriceCap.selector);
        new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                registryImpl.initialize,
                (
                    eSIMWalletAdmin,
                    vault,
                    upgradeManager,
                    address(deviceWalletFactory),
                    address(eSIMWalletFactory),
                    typeCastEntryPoint,
                    0
                )
            )
        );
    }

    /// @notice The price cap passed at initialization is recorded
    function test_initialize_recordsThePriceCap() public view {
        assertEq(
            registry.defaultPriceCapUSDCents(),
            defaultPriceCapUSDCents,
            "Registry should record the price cap passed at initialization"
        );
    }

    /// @notice Both factories are still recorded when neither is zero
    /// @dev Guards the guards: proves the new checks do not reject the intended deployment.
    function test_initialize_recordsBothFactories() public view {
        assertEq(
            address(registry.deviceWalletFactory()),
            address(deviceWalletFactory),
            "Registry should point at the deployed device wallet factory"
        );
        assertEq(
            address(registry.eSIMWalletFactory()),
            address(eSIMWalletFactory),
            "Registry should point at the deployed eSIM wallet factory"
        );
    }
}
