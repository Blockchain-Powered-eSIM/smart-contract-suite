// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {FuzzBase} from "test/foundry/fuzz-testing/base/FuzzBase.sol";

/// @notice How much ETH each path moves, over arbitrary amounts and arbitrary starting balances.
/// @dev Three things are being held at once. ETH is conserved, meaning what leaves one balance
///      arrives in another and nothing settles in a contract that has no way to send it on. The
///      price cap is honoured whichever of its two levels supplies it. And an amount larger than
///      the balance behind it fails rather than moving a partial amount.
///
///      The cap resolution is the part worth fuzzing rather than enumerating: the wallet's own cap
///      wins when set, the registry default applies when it is not, and zero means unlimited at
///      both levels. That last rule is the one a later change is most likely to break, because
///      zero reads as "no cap configured" and as "cap of nothing" equally well.
contract ETHAmountsTest is FuzzBase {

    /// @dev Keeps fuzzed amounts inside what vm.deal can fund without the totals overflowing
    uint256 private constant MAX_FUZZED_ETH = 1_000_000 ether;

    function setUp() public override {
        super.setUp();
        _deployFuzzWallets();

        vm.prank(eSIMWalletAdmin);
        fuzzDeviceWallet.setESIMUniqueIdentifierForAnESIMWallet(address(fuzzESIMWallet), "ESIM_FUZZ");
    }

    /// @notice Buying a bundle moves exactly its price to the vault and leaves nothing behind
    /// @dev The eSIM wallet pulls from the device wallet only for the shortfall, so the split
    ///      between the two balances is what has to add up. Anything left in the eSIM wallet that
    ///      was not there before is ETH the accounting lost track of.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundle_movesExactlyThePriceToTheVault(
        uint256 _price,
        uint256 _walletBalance,
        uint256 _deviceBalance
    ) public {
        uint256 price = bound(_price, 1, MAX_FUZZED_ETH);
        uint256 walletBalance = bound(_walletBalance, 0, MAX_FUZZED_ETH);
        uint256 deviceBalance = bound(_deviceBalance, price, MAX_FUZZED_ETH);

        vm.deal(address(fuzzESIMWallet), walletBalance);
        vm.deal(address(fuzzDeviceWallet), deviceBalance);
        uint256 vaultBefore = vault.balance;

        vm.prank(eSIMWalletAdmin);
        fuzzESIMWallet.buyDataBundle(DataBundleDetails("DB_FUZZ", price));

        assertEq(vault.balance - vaultBefore, price, "The vault must receive exactly the price");
        assertEq(
            address(fuzzESIMWallet).balance + address(fuzzDeviceWallet).balance + price,
            walletBalance + deviceBalance,
            "ETH must be conserved across the two wallets and the vault"
        );
    }

    /// @notice A price above the wallet's own cap is refused, and no ETH moves
    /// @dev The revert has to carry both numbers, because the caller cannot otherwise tell which of
    ///      the two levels refused it.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundle_refusesAPriceAboveTheWalletCap(uint256 _cap, uint256 _price) public {
        uint256 cap = bound(_cap, 1, MAX_FUZZED_ETH - 1);
        uint256 price = bound(_price, cap + 1, MAX_FUZZED_ETH);

        vm.prank(address(fuzzDeviceWallet));
        fuzzESIMWallet.setDataBundlePriceCap(cap);

        vm.deal(address(fuzzDeviceWallet), MAX_FUZZED_ETH);
        uint256 vaultBefore = vault.balance;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, price, cap));
        fuzzESIMWallet.buyDataBundle(DataBundleDetails("DB_FUZZ", price));

        assertEq(vault.balance, vaultBefore, "A refused purchase must move no ETH");
    }

    /// @notice With no cap on the wallet, the registry default is what refuses
    /// @dev The fallback only fires when the wallet's own cap is zero, so this is what says the two
    ///      levels are read in the right order rather than the default being ignored once a wallet
    ///      exists.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundle_fallsBackToTheRegistryCap(uint256 _cap, uint256 _price) public {
        uint256 cap = bound(_cap, 1, MAX_FUZZED_ETH - 1);
        uint256 price = bound(_price, cap + 1, MAX_FUZZED_ETH);

        vm.prank(registry.owner());
        registry.setDefaultDataBundlePriceCap(cap);

        assertEq(fuzzESIMWallet.dataBundlePriceCap(), 0, "The wallet must have no cap of its own");

        vm.deal(address(fuzzDeviceWallet), MAX_FUZZED_ETH);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, price, cap));
        fuzzESIMWallet.buyDataBundle(DataBundleDetails("DB_FUZZ", price));
    }

    /// @notice The wallet's own cap wins over the registry default, in both directions
    /// @dev Including the direction where the wallet's cap is the looser of the two. A resolution
    ///      that took the minimum of the two would pass a test that only ever set the wallet
    ///      tighter, and would silently cap wallets the device owner meant to raise.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundle_theWalletCapOverridesTheDefault(uint256 _walletCap, uint256 _price) public {
        uint256 walletCap = bound(_walletCap, 2, MAX_FUZZED_ETH);
        uint256 price = bound(_price, 1, walletCap);

        // The registry default is set tighter than the price, so a purchase that succeeds proves
        // the wallet's own cap is what was read
        vm.prank(registry.owner());
        registry.setDefaultDataBundlePriceCap(1);

        vm.prank(address(fuzzDeviceWallet));
        fuzzESIMWallet.setDataBundlePriceCap(walletCap);

        vm.deal(address(fuzzDeviceWallet), MAX_FUZZED_ETH);
        uint256 vaultBefore = vault.balance;

        vm.prank(eSIMWalletAdmin);
        fuzzESIMWallet.buyDataBundle(DataBundleDetails("DB_FUZZ", price));

        assertEq(vault.balance - vaultBefore, price, "The wallet's own cap must be the one that applies");
    }

    /// @notice Zero at both levels means unlimited rather than a cap of nothing
    /// @dev The rule a later change is most likely to invert, since zero reads as "not configured"
    ///      and as "nothing allowed" equally well. Inverting it stops every purchase on every
    ///      wallet that never set a cap, which is all of them by default.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundle_zeroCapMeansUnlimited(uint256 _price) public {
        uint256 price = bound(_price, 1, MAX_FUZZED_ETH);

        assertEq(fuzzESIMWallet.dataBundlePriceCap(), 0, "The wallet must have no cap of its own");
        assertEq(registry.defaultDataBundlePriceCap(), 0, "The registry must have no default cap");

        vm.deal(address(fuzzDeviceWallet), MAX_FUZZED_ETH);
        uint256 vaultBefore = vault.balance;

        vm.prank(eSIMWalletAdmin);
        fuzzESIMWallet.buyDataBundle(DataBundleDetails("DB_FUZZ", price));

        assertEq(vault.balance - vaultBefore, price, "A zero cap must not refuse any price");
    }

    /// @notice Pulling more than the device wallet holds fails and moves nothing
    /// @dev The failure has to be total. A partial transfer would leave the eSIM wallet holding ETH
    ///      the device wallet still believes it has.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_pullETH_cannotOverdrawTheDeviceWallet(uint256 _balance, uint256 _amount) public {
        uint256 balance = bound(_balance, 0, MAX_FUZZED_ETH);
        uint256 amount = bound(_amount, balance + 1, MAX_FUZZED_ETH + 1);

        vm.deal(address(fuzzDeviceWallet), balance);
        uint256 walletBefore = address(fuzzESIMWallet).balance;

        vm.prank(address(fuzzESIMWallet));
        vm.expectRevert();
        fuzzDeviceWallet.pullETH(amount);

        assertEq(address(fuzzDeviceWallet).balance, balance, "A failed pull must leave the balance alone");
        assertEq(address(fuzzESIMWallet).balance, walletBefore, "A failed pull must deliver nothing");
    }

    /// @notice A pull the device wallet can cover moves exactly that amount and no more
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_pullETH_movesExactlyTheAmountRequested(uint256 _balance, uint256 _amount) public {
        uint256 balance = bound(_balance, 1, MAX_FUZZED_ETH);
        uint256 amount = bound(_amount, 1, balance);

        vm.deal(address(fuzzDeviceWallet), balance);
        uint256 walletBefore = address(fuzzESIMWallet).balance;

        vm.prank(address(fuzzESIMWallet));
        fuzzDeviceWallet.pullETH(amount);

        assertEq(address(fuzzDeviceWallet).balance, balance - amount, "The device wallet must lose exactly the amount");
        assertEq(address(fuzzESIMWallet).balance - walletBefore, amount, "The eSIM wallet must gain exactly the amount");
    }

    /// @notice Paying for a bundle straight from the device wallet conserves ETH
    /// @dev The other exit, which skips the eSIM wallet's balance entirely and sends to the vault.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_payETHForDataBundles_conservesETH(uint256 _balance, uint256 _amount) public {
        uint256 balance = bound(_balance, 1, MAX_FUZZED_ETH);
        uint256 amount = bound(_amount, 1, balance);

        vm.deal(address(fuzzDeviceWallet), balance);
        uint256 vaultBefore = vault.balance;

        vm.prank(address(fuzzESIMWallet));
        fuzzDeviceWallet.payETHForDataBundles(amount);

        assertEq(vault.balance - vaultBefore, amount, "The vault must receive exactly the amount");
        assertEq(address(fuzzDeviceWallet).balance, balance - amount, "The device wallet must lose exactly the amount");
    }

    /// @notice Both exits refuse a zero amount rather than succeeding as a no-op
    /// @dev Why the two fuzz bounds above start at one. A zero-amount call that succeeded would
    ///      emit a movement event carrying no movement, which is what an offchain indexer reading
    ///      those events would have to filter for.
    function test_zeroAmountsAreRefusedOnBothExits() public {
        vm.deal(address(fuzzDeviceWallet), 1 ether);

        vm.prank(address(fuzzESIMWallet));
        vm.expectRevert("_amount 0");
        fuzzDeviceWallet.pullETH(0);

        vm.prank(address(fuzzESIMWallet));
        vm.expectRevert("_amount 0");
        fuzzDeviceWallet.payETHForDataBundles(0);

        assertEq(address(fuzzDeviceWallet).balance, 1 ether, "No ETH may move on a refused call");
    }
}
