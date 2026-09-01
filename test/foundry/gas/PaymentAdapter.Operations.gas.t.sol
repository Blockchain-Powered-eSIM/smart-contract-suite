// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/CustomStructs.sol";
import {Asset} from "contracts/payments/PaymentAdapter.sol";

import {GasBase} from "test/foundry/gas/base/GasBase.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Gas for the currency table and the payment references.
/// @dev Every purchase on both paths spends a reference and reads a currency, so what is measured
///      here is added to each of them. The reference write is the one that matters: it is a cold
///      SSTORE that can never warm up, since a reference is spent once and never touched again.
///      The two setters are the owner's and run once per currency, so they are here as a record
///      rather than as something to tune.
contract PaymentAdapterOperationsGasTest is GasBase {

    string internal NAMESPACE = "PaymentAdapter.Operations";

    /// @dev A symbol the fixture has not already registered, so the write is a fresh entry.
    bytes32 internal constant ASSET_DAI = bytes32("DAI");

    /// @notice Adding a currency to the table
    function test_registerAsset() public {
        vm.prank(upgradeManager);
        paymentAdapter.registerAsset(ASSET_DAI, Asset({
            allowed: true,
            isDollarUnit: true,
            decimals: 18,
            token: user1
        }));
        vm.snapshotGasLastCall(NAMESPACE, "registerAsset: a currency not in the table");
    }

    /// @notice Withdrawing a currency already in the table
    /// @dev The entry stays and only `allowed` moves, so this is a warm write to a slot that is
    ///      already non-zero rather than a delete.
    function test_updateAsset() public {
        vm.prank(upgradeManager);
        paymentAdapter.updateAsset(ASSET_USDC, Asset({
            allowed: false,
            isDollarUnit: true,
            decimals: 6,
            token: settlementToken
        }));
        vm.snapshotGasLastCall(NAMESPACE, "updateAsset: withdrawing a currency");
    }

    /// @notice Converting a cent price into a currency's smallest unit
    /// @dev Two currencies because the exponent is read from the entry. Same work either way, and
    ///      the pair says so rather than leaving it to be assumed.
    function test_quote() public {
        paymentAdapter.quote(ASSET_USDC, TEST_PRICE_CENTS);
        vm.snapshotGasLastCall(NAMESPACE, "quote: 6 decimals");

        paymentAdapter.quote(ASSET_USD, TEST_PRICE_CENTS);
        vm.snapshotGasLastCall(NAMESPACE, "quote: 2 decimals");
    }

    /// @notice Reading back a currency entry
    /// @dev Every settled purchase does this once, to pick up the token address the payment is
    ///      recorded against.
    function test_resolveAsset() public {
        paymentAdapter.resolveAsset(ASSET_USDC);
        vm.snapshotGasLastCall(NAMESPACE, "resolveAsset");
    }

    /// @notice Paying the vault out of tokens already sent to the adapter
    /// @dev A first settlement writes the vault a balance it did not have, which costs more than
    ///      every one after it and would swamp the difference the two cases are here to show. So
    ///      the vault is paid once before either measurement and all three are recorded.
    function test_settle() public {
        (, MockESIMWallet eSIMWallet) = _deployDeviceWallet("Device_Settle", 0, 4_001);
        uint256 needed = settlementAmount(TEST_PRICE_CENTS);

        fundSettlementToken(address(paymentAdapter), needed);
        vm.prank(address(eSIMWallet));
        paymentAdapter.settle(ASSET_USDC, TEST_PRICE_CENTS, needed, address(eSIMWallet));
        vm.snapshotGasLastCall(NAMESPACE, "settle: the vault's first payment in this currency");

        fundSettlementToken(address(paymentAdapter), needed);
        vm.prank(address(eSIMWallet));
        paymentAdapter.settle(ASSET_USDC, TEST_PRICE_CENTS, needed, address(eSIMWallet));
        vm.snapshotGasLastCall(NAMESPACE, "settle: funded to the exact price");

        fundSettlementToken(address(paymentAdapter), needed * 2);
        vm.prank(address(eSIMWallet));
        paymentAdapter.settle(ASSET_USDC, TEST_PRICE_CENTS, needed * 2, address(eSIMWallet));
        vm.snapshotGasLastCall(NAMESPACE, "settle: funded above the price, with a refund");
    }

    /// @notice Spending a payment reference
    /// @dev The cold SSTORE both payment paths carry. Nothing ever reads the slot again, so this
    ///      is the floor under every purchase and there is no warm case to measure against it.
    function test_consumePaymentReference() public {
        vm.prank(address(registry));
        paymentAdapter.consumePaymentReference(paymentRef("gas-consume"));
        vm.snapshotGasLastCall(NAMESPACE, "consumePaymentReference: a reference not yet spent");
    }
}
