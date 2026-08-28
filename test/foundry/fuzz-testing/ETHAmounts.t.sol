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
///      The ceiling is in cents and the ETH that moves is in wei, so the two are fuzzed
///      independently. Nothing onchain relates them without a rate.
///
///      The cap resolution is the part worth fuzzing rather than enumerating: the wallet's own cap
///      wins when set, and the registry default applies when it is not. Zero on the wallet still
///      means "follow the registry", but the registry itself can never hold zero: `initialize` and
///      `setDefaultPriceCapUSDCents` both refuse it, so a real ceiling always applies somewhere.
contract ETHAmountsTest is FuzzBase {

    /// @dev Keeps fuzzed amounts inside what vm.deal can fund without the totals overflowing
    uint256 private constant MAX_FUZZED_ETH = 1_000_000 ether;

    /// @dev $10,000,000 in cents. Large enough to exercise the ceiling, small enough to read.
    uint64 private constant MAX_FUZZED_CENTS = 1_000_000_000;

    function setUp() public override {
        super.setUp();
        _deployFuzzWallets();

        vm.prank(eSIMWalletAdmin);
        registry.assignESIMIdentifier(address(fuzzESIMWallet), "ESIM_FUZZ");
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

        // This test is about conservation of ETH on a successful purchase, not cap behaviour, so
        // the wallet's own cap is raised out of the way.
        vm.prank(address(fuzzDeviceWallet));
        fuzzESIMWallet.setPriceCapUSDCents(MAX_FUZZED_CENTS);

        vm.deal(address(fuzzESIMWallet), walletBalance);
        vm.deal(address(fuzzDeviceWallet), deviceBalance);
        uint256 vaultBefore = vault.balance;

        vm.prank(eSIMWalletAdmin);
        fuzzESIMWallet.buyDataBundle(bundle("DB_FUZZ", TEST_PRICE_CENTS), price, nextRef());

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
    function testFuzz_buyDataBundle_refusesAPriceAboveTheWalletCap(uint64 _cap, uint64 _price) public {
        uint64 cap = uint64(bound(_cap, 1, MAX_FUZZED_CENTS - 1));
        uint64 price = uint64(bound(_price, uint256(cap) + 1, MAX_FUZZED_CENTS));

        vm.prank(address(fuzzDeviceWallet));
        fuzzESIMWallet.setPriceCapUSDCents(cap);

        vm.deal(address(fuzzDeviceWallet), MAX_FUZZED_ETH);
        uint256 vaultBefore = vault.balance;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, price, cap));
        fuzzESIMWallet.buyDataBundle(bundle("DB_FUZZ", price), 1 ether, nextRef());

        assertEq(vault.balance, vaultBefore, "A refused purchase must move no ETH");
    }

    /// @notice With no cap on the wallet, the registry default is what refuses
    /// @dev The fallback only fires when the wallet's own cap is zero, so this is what says the two
    ///      levels are read in the right order rather than the default being ignored once a wallet
    ///      exists.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundle_fallsBackToTheRegistryCap(uint64 _cap, uint64 _price) public {
        uint64 cap = uint64(bound(_cap, 1, MAX_FUZZED_CENTS - 1));
        uint64 price = uint64(bound(_price, uint256(cap) + 1, MAX_FUZZED_CENTS));

        vm.prank(registry.owner());
        registry.setDefaultPriceCapUSDCents(cap);

        assertEq(fuzzESIMWallet.priceCapUSDCents(), 0, "The wallet must have no cap of its own");

        vm.deal(address(fuzzDeviceWallet), MAX_FUZZED_ETH);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, price, cap));
        fuzzESIMWallet.buyDataBundle(bundle("DB_FUZZ", price), 1 ether, nextRef());
    }

    /// @notice The wallet's own cap wins over the registry default, in both directions
    /// @dev Including the direction where the wallet's cap is the looser of the two. A resolution
    ///      that took the minimum of the two would pass a test that only ever set the wallet
    ///      tighter, and would silently cap wallets the device owner meant to raise.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundle_theWalletCapOverridesTheDefault(uint64 _walletCap, uint64 _price) public {
        uint64 walletCap = uint64(bound(_walletCap, 2, MAX_FUZZED_CENTS));
        uint64 price = uint64(bound(_price, 1, walletCap));

        // The registry default is set tighter than the price, so a purchase that succeeds proves
        // the wallet's own cap is what was read
        vm.prank(registry.owner());
        registry.setDefaultPriceCapUSDCents(1);

        vm.prank(address(fuzzDeviceWallet));
        fuzzESIMWallet.setPriceCapUSDCents(walletCap);

        vm.deal(address(fuzzDeviceWallet), MAX_FUZZED_ETH);
        uint256 vaultBefore = vault.balance;

        vm.prank(eSIMWalletAdmin);
        fuzzESIMWallet.buyDataBundle(bundle("DB_FUZZ", price), 1 ether, nextRef());

        assertEq(vault.balance - vaultBefore, 1 ether, "The wallet's own cap must be the one that applies");
    }

    /// @notice A price within the registry default set at deployment succeeds without either
    /// wallet or admin ever configuring a cap of their own
    /// @dev The wallet-level zero still means "follow the registry", but the registry itself can
    /// never hold zero, so this is the uncapped-looking path that is actually always bounded.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundle_withinTheDeployTimeDefaultSucceeds(uint64 _price) public {
        uint64 price = uint64(bound(_price, 1, defaultPriceCapUSDCents));

        assertEq(fuzzESIMWallet.priceCapUSDCents(), 0, "The wallet must have no cap of its own");
        assertEq(
            registry.defaultPriceCapUSDCents(),
            defaultPriceCapUSDCents,
            "The registry must hold the cap it was deployed with"
        );

        vm.deal(address(fuzzDeviceWallet), MAX_FUZZED_ETH);
        uint256 vaultBefore = vault.balance;

        vm.prank(eSIMWalletAdmin);
        fuzzESIMWallet.buyDataBundle(bundle("DB_FUZZ", price), 1 ether, nextRef());

        assertEq(vault.balance - vaultBefore, 1 ether, "A price within the default must not be refused");
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
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, balance, amount));
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

    /// @notice A zero amount is refused rather than succeeding as a no-op
    /// @dev Why the fuzz bound above starts at one. A zero-amount call that succeeded would emit a
    ///      movement event carrying no movement, which is what an offchain indexer reading those
    ///      events would have to filter for.
    function test_zeroAmountIsRefused() public {
        vm.deal(address(fuzzDeviceWallet), 1 ether);

        vm.prank(address(fuzzESIMWallet));
        vm.expectRevert(Errors.ZeroAmount.selector);
        fuzzDeviceWallet.pullETH(0);

        assertEq(address(fuzzDeviceWallet).balance, 1 ether, "No ETH may move on a refused call");
    }

    /// @notice No caller binds a wallet with the right to pull ETH, whoever they are
    /// @dev Access control runs first, so an unauthorised caller is turned away before the flag is
    ///      read, and an authorised one is refused on the flag itself. Either way the wallet ends
    ///      up without the access.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_noCallerEverBindsWithETHAccess(uint256 _caller) public {
        address[5] memory callers = [
            eSIMWalletAdmin,
            address(registry),
            address(deviceWalletFactory),
            address(fuzzDeviceWallet),
            user1
        ];
        address caller = callers[bound(_caller, 0, callers.length - 1)];

        // Released and rebound rather than deployed fresh, to avoid a salt collision with the
        // wallets the base fixture already placed
        address wallet = address(fuzzESIMWallet);
        vm.prank(address(fuzzDeviceWallet));
        fuzzDeviceWallet.removeESIMWallet(wallet, false);

        vm.prank(caller);
        try fuzzDeviceWallet.addESIMWallet(wallet, true) {
            fail("A bind carrying ETH access must never succeed");
        } catch {}

        assertFalse(
            fuzzDeviceWallet.canPullETH(wallet),
            "A refused bind must leave the wallet without the right to pull ETH"
        );
    }
}
