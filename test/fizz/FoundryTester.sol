// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Handlers} from "./handlers/Handlers.sol";

/// @notice Contract to be used for quick testing with Foundry
contract FoundryTester is Test, Handlers {
    function setUp() public {
        setup();
    }

    // forge test --match-test test_sequence -vvv
    function test_sequence() public {
        // Add here call sequence to Handler's functions to reproduce failing property
    }

    /// @notice Every clamped handler, once, on the state `setup()` leaves behind
    /// @dev A handler that reverts on its first call is one the campaign never reaches past, and a
    ///      fuzzer reports that as low coverage rather than as an error. Running each once here is
    ///      what turns a mis-pranked caller into a failing test instead of a silent gap.
    function test_smoke_everyHandlerReachesTheProtocol() public {
        assertEq(deviceWallets.length, BOOTSTRAP_DEVICE_WALLETS, "bootstrap device wallets");
        assertEq(eSIMWallets.length, BOOTSTRAP_DEVICE_WALLETS, "bootstrap eSIM wallets");

        eSIMWallet_buyDataBundleWithToken_clamped(0, 1, 500, 1, false);
        eSIMWallet_buyDataBundleWithToken_clamped(1, 2, 500, 2, true);
        eSIMWallet_buyDataBundleWithToken_atCap(0, 3);
        eSIMWallet_buyDataBundleWithToken_dustPrice(1, 4);
        eSIMWallet_buyDataBundleWithToken_needsPull(2, 700, 5);

        assertGt(settlementERC20.balanceOf(vault), 0, "vault must have been paid");

        deviceWallet_pullToken_clamped(0, 1e6);
        deviceWallet_deployESIMWallet_clamped(0, 3);
        deviceWallet_toggleAccessToFunds_clamped(1, true);

        registry_recordSettledPurchase_clamped(0, 9, 400, 1e6, 9, true);
        registry_assignESIMIdentifier_clamped(0, 1, false);
        registry_bindESIMWallet_clamped(1);
        registry_consumePaymentReference_clamped(2, 20);

        lazyWalletRegistry_batchPopulateHistory_clamped(1, 1, 3, 250, false);
        lazyWalletRegistry_deployLazyWalletAndSetESIMIdentifier_clamped(1, 77, 1 ether, 5, false);
        lazyWalletRegistry_setHistoryForLazyWallet_clamped(1, 2, false);

        deviceWalletFactory_createAccount_clamped(41, 42, 0.1 ether, false);
        assertTrue(lastCounterfactualWallet != address(0), "createAccount must deploy");
        deviceWalletFactory_secondary(0, 0);
        deviceWalletFactory_deployDeviceWalletForUsers_clamped(51, 52, 2, 0.1 ether, false);

        eSIMWalletFactory_deployESIMWallet_clamped(0, 1);
        paymentAdapter_settle_funded(0, 300);

        eSIMWallet_requestTransferOwnership_clamped(0, 1);
        eSIMWallet_acceptOwnershipTransfer_clamped(0);

        // Every deployment route must have added to the population the campaign draws from
        assertGt(deviceWallets.length, BOOTSTRAP_DEVICE_WALLETS, "device wallet population grew");
        assertGt(eSIMWallets.length, BOOTSTRAP_DEVICE_WALLETS, "eSIM wallet population grew");
    }

    /// @notice Every global property holds on the state a run of the handlers leaves behind
    /// @dev A property that compiles proves nothing. This drives the protocol first, so each one is
    ///      evaluated against a population that has actually moved rather than against `setup()`.
    function test_smoke_everyGlobalPropertyHolds() public {
        test_smoke_everyHandlerReachesTheProtocol();

        assertTrue(property_historyIsAppendOnly(), "GL-01");
        assertTrue(property_historyCursorStaysInBounds(), "GL-02");
        assertTrue(property_deploymentCursorStaysInBounds(), "GL-03/04");
        assertTrue(property_latchesNeverFallBack(), "GL-05/14");
        assertTrue(property_spentReferencesStaySpent(), "GL-06");
        assertTrue(property_ownerKeysAreUniqueAndAgree(), "GL-07/08");
        assertTrue(property_identifiersAreClaimedOnce(), "GL-09/10");
        assertTrue(property_theCeilingAlwaysBinds(), "GL-11");
        assertTrue(property_settlementTokenIsConserved(), "GL-12");
        assertTrue(property_onlyThePurchasePathClaimsSettlement(), "GL-13");
        assertTrue(property_noUnauthorizedCallSucceeded(), "unauthorized call");

        // Running them twice matters: the append-only and latch properties compare against what the
        // first pass recorded, so a first pass alone would only ever be populating them.
        assertTrue(property_historyIsAppendOnly(), "GL-01 second pass");
        assertTrue(property_latchesNeverFallBack(), "GL-05/14 second pass");
        assertTrue(property_deploymentCursorStaysInBounds(), "GL-03/04 second pass");
    }

    /// @notice The properties must survive the calls that are supposed to be refused
    /// @dev Each call here reverts, which is the point, so each goes through `_expectRefused`. The
    ///      fuzzers discard a reverted call on their own; Foundry does not.
    function test_smoke_refusedCallsLeaveNoTrace() public {
        _expectRefused(abi.encodeCall(this.registry_recordSettledPurchase_assertsDeviceWallet, (0, 5)));
        _expectRefused(abi.encodeCall(this.registry_recordSettledPurchase_overCap, (0, 6)));
        _expectRefused(abi.encodeCall(this.registry_bindESIMWallet_asStranger, (0, 1)));
        _expectRefused(abi.encodeCall(this.eSIMWalletFactory_deployESIMWallet_forStranger, (0, 1, 2)));
        _expectRefused(abi.encodeCall(this.eSIMWallet_buyDataBundleWithToken_unsettleableAsset, (0, 7, true)));
        _expectRefused(abi.encodeCall(this.eSIMWallet_buyDataBundleWithToken_unsettleableAsset, (0, 8, false)));

        assertTrue(property_noUnauthorizedCallSucceeded(), "a refused call went through");
        assertTrue(property_onlyThePurchasePathClaimsSettlement(), "GL-13");
        assertTrue(property_theCeilingAlwaysBinds(), "GL-11");
    }

    /// @notice Nothing that moves value runs while the protocol is paused
    function test_smoke_pauseStopsEveryValueMovingPath() public {
        registry_secondary(0, 0);
        assertTrue(registry.paused(), "pause must apply");

        _expectRefused(abi.encodeCall(this.eSIMWallet_buyDataBundleWithToken_clamped, (0, 1, 100, 40, false)));
        _expectRefused(abi.encodeCall(this.deviceWallet_pullToken_clamped, (0, 1e6)));
        _expectRefused(abi.encodeCall(this.registry_recordSettledPurchase_clamped, (0, 2, 100, 0, 41, true)));
        _expectRefused(
            abi.encodeCall(this.lazyWalletRegistry_deployLazyWalletAndSetESIMIdentifier_clamped, (2, 88, 1 ether, 5, false))
        );

        assertTrue(property_noUnauthorizedCallSucceeded(), "a guarded path ran while paused");
    }

    /// @notice Runs a handler that is expected to revert, and fails if it did not
    /// @dev Through an external self-call so the revert unwinds only the handler. A handler that
    ///      quietly returned instead of reverting would otherwise read as a pass.
    function _expectRefused(bytes memory call) private {
        (bool ok,) = address(this).call(call);
        assertFalse(ok, "a call the protocol should have refused went through");
    }

    /// @notice The config surface, which every other handler reads its permissions from
    function test_smoke_configHandlersApplyAndRevert() public {
        registry_secondary(0, 0); // pause
        assertTrue(registry.paused(), "pause must apply");

        registry_secondary(1, 0); // unpause
        assertFalse(registry.paused(), "unpause must apply");

        registry_secondary(3, 1); // rotate onto the spare adapter
        assertEq(registry.paymentAdapter(), address(spareAdapter), "adapter must rotate");

        registry_secondary(3, 0); // and back
        assertEq(registry.paymentAdapter(), address(paymentAdapter), "adapter must rotate back");

        registry_secondary(2, 5_000); // price cap
        assertEq(registry.defaultPriceCapUSDCents(), 5_000, "cap must apply");

        registry_secondary(7, 0); // nominate a successor
        registry_secondary(8, 0); // and let it accept
        assertEq(registry.eSIMWalletAdmin(), adminSuccessor, "admin must rotate");

        // The admin handlers read the role live, so a purchase still works after the rotation
        eSIMWallet_buyDataBundleWithToken_clamped(0, 1, 100, 31, true);

        deviceWalletFactory_secondary(1, 0); // swap the device wallet beacon
        eSIMWalletFactory_secondary(0, 0); // swap the eSIM wallet beacon
        paymentAdapter_secondary(0, 1, 6); // register a currency
    }

    // ── Violation Repros (auto-generated by Step 11) ──────────────────
    // Each test_repro_* function below replays a shrunk fuzzer call
    // sequence that violated a property. Run all with:
    //   forge test --match-contract FoundryTester -vvv
}
