// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/CustomStructs.sol";

import {GasBase} from "test/foundry/gas/base/GasBase.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Gas for what an eSIM wallet does, and for the eSIM wallet factory's deploy.
/// @dev `buyDataBundle` is the only path a user hits repeatedly, and it has two shapes. A wallet
///      holding enough ETH pays the vault directly; one that does not reaches back into the device
///      wallet first. The second is an extra external call into a second proxy, and the pair is here
///      because the difference decides whether topping a wallet up is worth doing.
contract ESIMWalletOperationsGasTest is GasBase {

    string internal NAMESPACE = "ESIMWallet.Operations";

    MockDeviceWallet internal wallet;
    MockESIMWallet internal eSIMWallet;

    /// @dev DeployerBase does not declare setUp virtual, so the wallet pair is deployed per test.
    function _deploy() internal {
        (wallet, eSIMWallet) = _deployDeviceWallet(customDeviceUniqueIdentifiers[0], 0, 8600);
        vm.deal(address(wallet), 100 ether);

        vm.prank(address(wallet));
        wallet.toggleAccessToETH(address(eSIMWallet), true);
    }

    /// @notice Deploying an eSIM wallet through the factory
    function test_deployESIMWallet() public {
        _deploy();

        vm.prank(address(registry));
        eSIMWalletFactory.deployESIMWallet(address(wallet), 8601);
        vm.snapshotGasLastCall(NAMESPACE, "deployESIMWallet: through the factory");
    }

    /// @notice Buying a data bundle, funded and unfunded
    /// @dev The unfunded case is the common one. A wallet holds no float, so every purchase pulls
    ///      from the device wallet and pays the vault in the same call.
    function test_buyDataBundle() public {
        _deploy();

        vm.deal(address(eSIMWallet), 10 ether);
        vm.prank(address(wallet));
        eSIMWallet.buyDataBundle(bundle("DB_GAS_1", TEST_PRICE_CENTS), 1 ether, paymentRef("gas-1"));
        vm.snapshotGasLastCall(NAMESPACE, "buyDataBundle: wallet already holds the price");

        vm.deal(address(eSIMWallet), 0);
        vm.prank(address(wallet));
        eSIMWallet.buyDataBundle(bundle("DB_GAS_2", TEST_PRICE_CENTS), 1 ether, paymentRef("gas-2"));
        vm.snapshotGasLastCall(NAMESPACE, "buyDataBundle: pulls from the device wallet");
    }

    /// @notice Naming an eSIM after its wallet exists
    /// @dev One-shot per wallet, so the second wallet on the device is the one measured here.
    function test_setESIMUniqueIdentifier() public {
        _deploy();

        vm.prank(eSIMWalletAdmin);
        address fresh = wallet.deployESIMWallet(false, 8602);

        vm.prank(address(registry));
        MockESIMWallet(payable(fresh)).setESIMUniqueIdentifier("eSIM_gas_identifier");
        vm.snapshotGasLastCall(NAMESPACE, "setESIMUniqueIdentifier: first time");
    }

    /// @notice Moving the wallet's own price ceiling, and handing it back to the registry's
    function test_setPriceCapUSDCents() public {
        _deploy();

        vm.prank(address(wallet));
        eSIMWallet.setPriceCapUSDCents(5 ether);
        vm.snapshotGasLastCall(NAMESPACE, "setPriceCapUSDCents: set");

        vm.prank(address(wallet));
        eSIMWallet.setPriceCapUSDCents(0);
        vm.snapshotGasLastCall(NAMESPACE, "setPriceCapUSDCents: back to the registry ceiling");
    }

    /// @notice The two halves of an eSIM wallet ownership transfer
    /// @dev Both ends have to be real device wallets. The request also unbinds the eSIM wallet from
    ///      its current device and sweeps its ETH back, so the first half carries more than the name
    ///      suggests.
    function test_ownershipTransfer() public {
        _deploy();
        (MockDeviceWallet newOwner,) = _deployDeviceWallet(customDeviceUniqueIdentifiers[1], 1, 8603);

        vm.prank(address(wallet));
        eSIMWallet.requestTransferOwnership(address(newOwner));
        vm.snapshotGasLastCall(NAMESPACE, "requestTransferOwnership");

        vm.prank(address(newOwner));
        eSIMWallet.acceptOwnershipTransfer();
        vm.snapshotGasLastCall(NAMESPACE, "acceptOwnershipTransfer");
    }

    /// @notice Appending pre-deployment purchase history, one batch
    function test_populateHistory() public {
        _deploy();

        DataBundleDetails[] memory history = new DataBundleDetails[](10);
        for(uint256 i = 0; i < history.length; ++i) {
            history[i] = bundle("DB_GAS_HISTORY", TEST_PRICE_CENTS);
        }

        vm.prank(address(registry));
        eSIMWallet.populateHistory(history);
        vm.snapshotGasLastCall(NAMESPACE, "populateHistory: 10 entries");
    }
}
