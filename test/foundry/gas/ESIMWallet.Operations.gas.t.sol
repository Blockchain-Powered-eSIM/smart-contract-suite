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
        wallet.toggleAccessToFunds(address(eSIMWallet), true);
    }

    /// @notice Deploying an eSIM wallet through the factory
    function test_deployESIMWallet() public {
        _deploy();

        vm.prank(address(registry));
        eSIMWalletFactory.deployESIMWallet(address(wallet), 8601);
        vm.snapshotGasLastCall(NAMESPACE, "deployESIMWallet: through the factory");
    }

    /// @notice Buying a data bundle with USDC (or any other acceptable stablecoin/ERC20), funded and unfunded
    /// @dev The unfunded case is the common one and costs a pull on top. A first purchase writes
    ///      the vault a balance it did not have, so one runs unmeasured before either figure is
    ///      taken and the two are then comparable.
    function test_buyDataBundleWithToken() public {
        _deploy();
        uint256 needed = settlementAmount(TEST_PRICE_CENTS);

        fundSettlementToken(address(eSIMWallet), needed);
        vm.prank(address(wallet));
        eSIMWallet.buyDataBundleWithToken(bundle("DB_TOK_0", TEST_PRICE_CENTS), ASSET_USDC, needed, paymentRef("gas-tok-0"));

        fundSettlementToken(address(eSIMWallet), needed);
        vm.prank(address(wallet));
        eSIMWallet.buyDataBundleWithToken(bundle("DB_TOK_1", TEST_PRICE_CENTS), ASSET_USDC, needed, paymentRef("gas-tok-1"));
        vm.snapshotGasLastCall(NAMESPACE, "buyDataBundleWithToken: wallet already holds the price");

        fundSettlementToken(address(wallet), needed);
        vm.prank(address(wallet));
        eSIMWallet.buyDataBundleWithToken(bundle("DB_TOK_2", TEST_PRICE_CENTS), ASSET_USDC, needed, paymentRef("gas-tok-2"));
        vm.snapshotGasLastCall(NAMESPACE, "buyDataBundleWithToken: pulls from the device wallet");
    }

    /// @notice Returning a token balance to the owning device wallet
    function test_sendTokenToDeviceWallet() public {
        _deploy();
        fundSettlementToken(address(eSIMWallet), 100e6);

        vm.prank(address(wallet));
        eSIMWallet.sendTokenToDeviceWallet(settlementToken, 100e6);
        vm.snapshotGasLastCall(NAMESPACE, "sendTokenToDeviceWallet: the whole balance");
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
        eSIMWallet.setPriceCapUSDCents(50_000);
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
