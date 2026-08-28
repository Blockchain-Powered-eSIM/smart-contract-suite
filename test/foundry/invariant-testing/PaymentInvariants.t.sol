// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {CampaignBase} from "test/foundry/invariant-testing/base/CampaignBase.sol";

/// @notice What has to stay true about payment references and the currency table.
/// @dev The whole campaign runs underneath these, so both hold while wallets are being
///      transferred, removed and moved onto new beacon logic.
contract PaymentInvariantsTest is CampaignBase {

    bytes32[3] private symbols = [bytes32("USD"), bytes32("USDC"), bytes32("ETH")];

    /// @notice One payment reference pays for one purchase, whichever path spends it
    /// @dev A reference is one offchain payment. The backend retries the whole onchain step on any
    ///      failure, so a reference that could be spent a second time is a user charged once and
    ///      billed twice. The two payment paths reach the adapter by different routes, which is
    ///      what makes this a question about the pair rather than about either one.
    function invariant_aPaymentReferenceIsSpentAtMostOnce() public view {
        assertFalse(
            paymentHandler.ghost_referenceSpentTwice(),
            "A payment reference paid for a second purchase"
        );

        uint256 count = paymentHandler.spentReferenceCount();
        for (uint256 i = 0; i < count; ++i) {
            bytes32 paymentReference = paymentHandler.spentReferences(i);

            assertEq(
                paymentHandler.ghost_spendCount(paymentReference),
                1,
                "A payment reference was spent more than once"
            );
            assertTrue(
                paymentAdapter.usedReferences(paymentReference),
                "A reference a purchase spent does not read as spent"
            );
        }
    }

    /// @notice A currency the table has withdrawn never returns a price
    /// @dev The withdrawal is what stops a purchase being recorded against a currency the protocol
    ///      no longer accepts, so an answer that outlives it would leave the withdrawal meaning
    ///      nothing.
    function invariant_aWithdrawnCurrencyNeverQuotes() public {
        assertFalse(
            paymentHandler.ghost_withdrawnCurrencyQuoted(),
            "A withdrawn currency returned a price"
        );

        for (uint256 i = 0; i < symbols.length; ++i) {
            (bool allowed,,,) = paymentAdapter.assets(symbols[i]);
            if (allowed) continue;

            bool quoted = true;
            try paymentAdapter.quote(symbols[i], 100) returns (uint256) {}
            catch {
                quoted = false;
            }

            assertFalse(quoted, "A withdrawn currency returned a price");
        }
    }
}
