// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {DataBundleDetails, Settlement} from "contracts/CustomStructs.sol";
import {PaymentAdapter} from "contracts/payments/PaymentAdapter.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

import {Snapshots} from "./Snapshots.sol";
import {PropertiesAsserts} from "./utils/PropertiesAsserts.sol";

/// @notice Contains the functions that check the properties (invariants)
/// @dev The global properties walk the wallets the campaign has built, so each is linear in the
///      population rather than quadratic. The one genuinely cross-product check, that a device
///      wallet and the registry agree on who holds an eSIM wallet, is written from the eSIM
///      wallet's side, where the registry already names the single device wallet to ask.
abstract contract Properties is PropertiesAsserts, Snapshots {

    // ―――――――――――――――――――― Global properties ―――――――――――――――――――――
    // These properties must always hold after any function call.
    // They MUST BE PUBLIC so that fuzzers can find and call them.

    /// @notice GL-01: an eSIM wallet's purchase history is append-only, entry for entry
    /// @dev The repo's own notes record a mutation that made a purchase overwrite entry zero, which
    ///      nothing in the suite caught. A length check alone would still miss it, so every entry
    ///      already seen is re-hashed against what it hashed to last time.
    function property_historyIsAppendOnly() public returns (bool) {
        for (uint256 i; i < eSIMWallets.length; ++i) {
            address wallet = eSIMWallets[i];
            DataBundleDetails[] memory entries = MockESIMWallet(payable(wallet)).getTransactionHistory();

            uint256 known = ghosts.historyLength[wallet];
            if (entries.length < known) return false;

            for (uint256 j; j < entries.length; ++j) {
                bytes32 digest = keccak256(
                    abi.encode(entries[j].id, entries[j].priceUSDCents, entries[j].settlement)
                );
                if (j < known) {
                    if (ghosts.historyEntry[wallet][j] != digest) return false;
                } else {
                    ghosts.historyEntry[wallet][j] = digest;
                }
            }
            ghosts.historyLength[wallet] = entries.length;
        }
        return true;
    }

    /// @notice GL-02: the history copy cursor never runs backwards or past the end
    function property_historyCursorStaysInBounds() public returns (bool) {
        string[] memory identifiers = _allLazyESIMIdentifiers();

        for (uint256 i; i < identifiers.length; ++i) {
            string memory identifier = identifiers[i];
            uint256 copied = lazyWalletRegistry.historyEntriesCopied(identifier);

            if (copied < ghosts.lastCopied[identifier]) return false;
            ghosts.lastCopied[identifier] = copied;

            // Read through the live redirect: a switch moves the entries to another device, and the
            // cursor follows the identifier rather than the device it used to sit under.
            string memory device = lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(identifier);
            if (bytes(device).length == 0) {
                if (copied != 0) return false;
                continue;
            }
            if (copied > lazyWalletRegistry.getDeviceIdentifierToESIMDetails(device, identifier).length) {
                return false;
            }
        }
        return true;
    }

    /// @notice GL-03 and GL-04: the deployment cursor stays in bounds, and the list it is measured
    ///         against stops changing once the device has a wallet
    /// @dev The two are checked together because the bound is only safe while the freeze holds.
    ///      Checking the freeze separately is what tells the two apart when one breaks.
    function property_deploymentCursorStaysInBounds() public returns (bool) {
        string[] memory identifiers = _allLazyDeviceIdentifiers();

        for (uint256 i; i < identifiers.length; ++i) {
            string memory identifier = identifiers[i];
            uint256 deployed = lazyWalletRegistry.eSIMWalletsDeployed(identifier);
            uint256 associated =
                lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(identifier).length;

            if (deployed < ghosts.lastDeployed[identifier]) return false;
            ghosts.lastDeployed[identifier] = deployed;

            if (deployed > associated) return false;

            if (registry.isDeviceIdentifierAlreadyUsed(identifier)) {
                if (!ghosts.listFrozen[identifier]) {
                    ghosts.listFrozen[identifier] = true;
                    ghosts.frozenLength[identifier] = associated;
                } else if (ghosts.frozenLength[identifier] != associated) {
                    return false;
                }
            }
        }
        return true;
    }

    /// @notice GL-05 and GL-14: every latch in the protocol still holds
    /// @dev All one-way, all cheap to read, so they ride together rather than as five properties
    ///      the fuzzer has to call separately after every call.
    function property_latchesNeverFallBack() public returns (bool) {
        for (uint256 i; i < eSIMWallets.length; ++i) {
            address wallet = eSIMWallets[i];

            if (registry.isESIMWalletValid(wallet) != address(0)) ghosts.everRegisteredESIM[wallet] = true;
            else if (ghosts.everRegisteredESIM[wallet]) return false;

            if (eSIMWalletFactory.isESIMWalletDeployed(wallet)) ghosts.everDeployedESIM[wallet] = true;
            else if (ghosts.everDeployedESIM[wallet]) return false;
        }

        for (uint256 i; i < deviceWallets.length; ++i) {
            address wallet = deviceWallets[i];
            if (registry.isDeviceWalletValid(wallet)) ghosts.everValidDevice[wallet] = true;
            else if (ghosts.everValidDevice[wallet]) return false;
        }

        return _assetTableHolds();
    }

    /// @notice GL-06: a spent payment reference never un-spends
    function property_spentReferencesStaySpent() public view returns (bool) {
        for (uint256 i; i < ghosts.spentReferences.length; ++i) {
            if (!registry.usedPaymentReferences(ghosts.spentReferences[i])) return false;
        }
        return true;
    }

    /// @notice GL-07 and GL-08: one P256 key names one device wallet, and both copies of the key agree
    function property_ownerKeysAreUniqueAndAgree() public view returns (bool) {
        for (uint256 i; i < deviceWallets.length; ++i) {
            address wallet = deviceWallets[i];
            if (!registry.isDeviceWalletValid(wallet)) continue;

            bytes32[2] memory registryKey = registry.getDeviceWalletToOwner(wallet);
            bytes32[2] memory walletKey = MockDeviceWallet(payable(wallet)).getOwner();

            if (registryKey[0] != walletKey[0] || registryKey[1] != walletKey[1]) return false;
            if (registry.registeredP256Keys(keccak256(abi.encode(registryKey[0], registryKey[1]))) != wallet) {
                return false;
            }
        }
        return true;
    }

    /// @notice GL-09 and GL-10: an identifier names one wallet, and that wallet names it back
    function property_identifiersAreClaimedOnce() public view returns (bool) {
        for (uint256 i; i < deviceWallets.length; ++i) {
            address wallet = deviceWallets[i];
            if (!registry.isDeviceWalletValid(wallet)) continue;

            string memory identifier = MockDeviceWallet(payable(wallet)).deviceUniqueIdentifier();
            if (registry.uniqueIdentifierToDeviceWallet(identifier) != wallet) return false;
        }

        for (uint256 i; i < eSIMWallets.length; ++i) {
            address wallet = eSIMWallets[i];
            string memory identifier = MockESIMWallet(payable(wallet)).eSIMUniqueIdentifier();
            if (bytes(identifier).length == 0) continue;

            if (registry.eSIMWalletForIdentifier(identifier) != wallet) return false;
        }
        return true;
    }

    /// @notice GL-11: the ceiling always means something, and nothing was ever written over it
    /// @dev The cap is checked when an entry is written, and the owner may lower it afterwards, so
    ///      comparing old entries against today's cap would report every legal purchase made before
    ///      a reduction. The per-entry check is done at write time in the handlers instead, and its
    ///      result is carried here. What is genuinely a standing property is the other half: the
    ///      registry default is never zero, because zero reads as "no ceiling" everywhere a cap is
    ///      consumed, which would quietly remove the bound the admin is held to.
    function property_theCeilingAlwaysBinds() public view returns (bool) {
        if (registry.defaultPriceCapUSDCents() == 0) return false;
        return !ghosts.purchaseAboveCap;
    }

    /// @notice GL-12: settlement token is never created or destroyed
    function property_settlementTokenIsConserved() public view returns (bool) {
        uint256 tracked = settlementERC20.balanceOf(address(this)) + sumActorsERC20Balances(settlementToken)
            + settlementERC20.balanceOf(address(paymentAdapter)) + settlementERC20.balanceOf(address(spareAdapter))
            + settlementERC20.balanceOf(vault) + settlementERC20.balanceOf(spareVault);

        for (uint256 i; i < deviceWallets.length; ++i) {
            tracked += settlementERC20.balanceOf(deviceWallets[i]);
        }
        for (uint256 i; i < eSIMWallets.length; ++i) {
            tracked += settlementERC20.balanceOf(eSIMWallets[i]);
        }

        return settlementERC20.totalSupply() == tracked;
    }

    /// @notice GL-13: only the path that moved the money may say it did
    function property_onlyThePurchasePathClaimsSettlement() public view returns (bool) {
        for (uint256 i; i < eSIMWallets.length; ++i) {
            address wallet = eSIMWallets[i];
            DataBundleDetails[] memory entries = MockESIMWallet(payable(wallet)).getTransactionHistory();

            uint256 claimed;
            for (uint256 j; j < entries.length; ++j) {
                if (entries[j].settlement == Settlement.DeviceWallet) ++claimed;
            }
            if (claimed != ghosts.witnessedPurchases[wallet]) return false;
        }
        return true;
    }

    /// @notice A call the protocol should have refused went through
    /// @dev Every flag here is written by a handler that watched a gated call succeed for a caller
    ///      the guard names. Kept out of the handler bodies because an assertion there reverts the
    ///      call, and a reverted call is thrown away rather than reported.
    function property_noUnauthorizedCallSucceeded() public view returns (bool) {
        return !ghosts.unauthorizedBind && !ghosts.unauthorizedStandby && !ghosts.unauthorizedPull
            && !ghosts.unauthorizedForeignDeploy && !ghosts.pausedCallSucceeded;
    }

    /// @notice Every global property, as one assertion
    /// @dev Medusa reads the `property_` functions above directly. Echidna running in assertion
    ///      mode does not: it looks for a failed assert rather than a false return, so without this
    ///      the whole global set would be invisible to it and only the inline checks inside the
    ///      handlers would carry the run. Both engines call this, which costs Medusa a second pass
    ///      over state it has already read and buys a second, independent explorer over all of it.
    function checkAllGlobalProperties() public {
        t(property_historyIsAppendOnly(), "GL-01 purchase history was rewritten");
        t(property_historyCursorStaysInBounds(), "GL-02 history cursor left its bounds");
        t(property_deploymentCursorStaysInBounds(), "GL-03/04 deployment cursor left its bounds");
        t(property_latchesNeverFallBack(), "GL-05/14 a latch fell back");
        t(property_spentReferencesStaySpent(), "GL-06 a spent payment reference un-spent");
        t(property_ownerKeysAreUniqueAndAgree(), "GL-07/08 owner keys disagree or are shared");
        t(property_identifiersAreClaimedOnce(), "GL-09/10 an identifier names the wrong wallet");
        t(property_theCeilingAlwaysBinds(), "GL-11 the price ceiling stopped binding");
        t(property_settlementTokenIsConserved(), "GL-12 settlement token was created or destroyed");
        t(property_onlyThePurchasePathClaimsSettlement(), "GL-13 something else claimed settlement");
        t(property_noUnauthorizedCallSucceeded(), "a call the protocol should have refused ran");
    }

    // ――――――――――――――――――― Specific properties ――――――――――――――――――――
    // These properties must hold after specific function calls.
    // They MUST BE INTERNAL and called at the end of the relevant handlers.

    /// @notice SP-01: a purchase moves value between four addresses and creates none, and leaves
    ///         nothing resting on the adapter
    function _prop_purchaseConservesValue() internal {
        eq(stateAfter.purchaseSideTotal, stateBefore.purchaseSideTotal, "SP-01 purchase created or destroyed value");
        eq(stateAfter.adapterBalance, stateBefore.adapterBalance, "SP-01 tokens rested on the adapter");
    }

    /// @notice SP-02: what the adapter spent matches a formula written here rather than read back
    function _prop_settlementMatchesReference(uint64 priceUSDCents, uint256 spent) internal {
        eq(spent, _settlementAmount(priceUSDCents), "SP-02 settled amount diverged from the reference conversion");
    }

    /// @notice SP-03: the quote is exact and monotonic
    /// @dev Decimals are held at or above two, so `10 ** decimals` is always a multiple of a
    ///      hundred and the division cannot drop a remainder. That makes this an equality rather
    ///      than a bound.
    function _prop_quoteIsExact(uint64 priceUSDCents, uint8 decimals, uint256 amount) internal {
        eq(amount * 100, uint256(priceUSDCents) * 10 ** decimals, "SP-03 quote lost precision");
    }

    function _prop_quoteIsMonotonic(uint256 lowQuote, uint256 highQuote, bool pricesDiffer) internal {
        gte(highQuote, lowQuote, "SP-03 quote fell as the price rose");
        if (pricesDiffer) gt(highQuote, lowQuote, "SP-03 quote did not move for a higher price");
    }

    /// @notice SP-04: a wallet lands where the factory said it would
    function _prop_addressMatchesPrediction(address predicted, address deployed) internal {
        t(predicted == deployed, "SP-04 deployed address diverged from the prediction");
    }

    /// @notice SP-05: a handover does not carry the old owner's ceiling
    /// @dev The outgoing owner sets that cap and controls it right up to the moment it hands the
    ///      wallet over, so an incoming owner inheriting it would be inheriting a ceiling it never
    ///      agreed to.
    function _prop_handoverClearsThePriceCap(address eSIMWallet) internal {
        eq(
            uint256(MockESIMWallet(payable(eSIMWallet)).priceCapUSDCents()),
            0,
            "SP-05 the old owner's price ceiling survived the handover"
        );
    }

    /// @notice SP-06: accepting ownership does not rewrite the registry association
    /// @dev The divergence is deliberate. Authorization reads the wallet's live owner, which is why
    ///      the association is allowed to go on naming whoever last bound it.
    function _prop_handoverLeavesTheAssociation(address eSIMWallet, address associationBefore) internal {
        t(
            registry.isESIMWalletValid(eSIMWallet) == associationBefore,
            "SP-06 accepting ownership moved the association"
        );
    }

    /// @notice SP-07: raising or clearing standby never touches the registration
    /// @dev The two mappings are independent. Deriving one from the other is a defect this repo has
    ///      already shipped once, so the inverse of this property would be wrong.
    function _prop_standbyLeavesTheRegistration(address eSIMWallet, address registrationBefore) internal {
        t(
            registry.isESIMWalletValid(eSIMWallet) == registrationBefore,
            "SP-07 a standby change rewrote the registration"
        );
    }

    /// @notice SP-08: a removal strips both flags, and a re-add never hands spend rights back
    function _prop_removalStripsAccess(address deviceWallet, address eSIMWallet) internal {
        t(!MockDeviceWallet(payable(deviceWallet)).isValidESIMWallet(eSIMWallet), "SP-08 removal left the wallet valid");
        t(!MockDeviceWallet(payable(deviceWallet)).canPullFunds(eSIMWallet), "SP-08 removal left funds access");
    }

    function _prop_bindingGrantsNoAccess(address deviceWallet, address eSIMWallet) internal {
        t(
            !MockDeviceWallet(payable(deviceWallet)).canPullFunds(eSIMWallet),
            "SP-08 binding handed back funds access without an owner signature"
        );
    }

    /// @notice SP-09: a deployed but unregistered device wallet can do nothing
    function _prop_unregisteredWalletIsInert(address wallet, string memory identifier) internal {
        t(!registry.isDeviceWalletValid(wallet), "SP-09 an unregistered wallet reads as valid");
        t(
            registry.uniqueIdentifierToDeviceWallet(identifier) != wallet,
            "SP-09 an unregistered wallet already claims its identifier"
        );
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    /// @notice Every registered currency is inside the decimals window, and none has un-registered
    function _assetTableHolds() private returns (bool) {
        bytes32[] memory symbols = _allSymbols();
        address[2] memory adapters = [address(paymentAdapter), address(spareAdapter)];

        for (uint256 a; a < adapters.length; ++a) {
            for (uint256 s; s < symbols.length; ++s) {
                // The plain getter, not `resolveAsset`, which reverts on a currency the owner has
                // withdrawn. A withdrawn currency is still registered and still has to be in bounds.
                (,, uint8 decimals,) = PaymentAdapter(adapters[a]).assets(symbols[s]);

                if (decimals == 0) {
                    if (ghosts.everRegisteredAsset[adapters[a]][symbols[s]]) return false;
                    continue;
                }
                ghosts.everRegisteredAsset[adapters[a]][symbols[s]] = true;
                if (decimals < 2 || decimals > 36) return false;
            }
        }
        return true;
    }
}
