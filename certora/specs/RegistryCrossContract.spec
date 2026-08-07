/// Registry, DeviceWallet and ESIMWallet: whether the three agree on who holds an eSIM wallet.
///
/// Every other spec in this directory proves one contract's storage against itself. This one is the
/// only cross-contract statement, and it is the one worth having, because the fact it fixes is split
/// across three contracts and no single one of them can be read to check it. A device wallet says
/// which eSIM wallets it holds, in `isValidESIMWallet`. The registry says which device wallet an
/// eSIM wallet belongs to, in `isESIMWalletValid`. The eSIM wallet itself says who owns it, through
/// `Ownable`. All three are written by different calls, and the ownership transfer moves them one at
/// a time rather than together.
///
/// The scene therefore holds three linked instances rather than one contract and a wall of NONDET.
/// That matters more here than anywhere else: the guard that keeps a device wallet from binding an
/// eSIM wallet it does not own reads `ESIMWallet.owner()`, so under a NONDET summary the guard
/// answers arbitrarily and any device wallet walks in. The rules below would then fail for a reason
/// that exists only in the model. With the eSIM wallet in the scene the call resolves and the guard
/// is the one the chain runs.
///
/// The price is that the statement is about one linked triple rather than every triple. A rule here
/// says: this device wallet, this eSIM wallet and this registry never come apart, over every method
/// of all three contracts. It does not quantify over other device wallets, and the second rule is
/// where that shows, since a second device wallet is exactly the party the guard is against. The
/// note on that rule says what is and is not covered.
///
/// The direction is one way, and this is the correction rather than an omission. The two mappings
/// were once thought to be halves of one fact, and the milestone list asked for a biconditional:
/// `isESIMWalletValid[e] == d` if and only if `d.isValidESIMWallet[e]`. That is false, and it is
/// false on the normal path. `isESIMWalletValid` is a registration that also names the last device
/// wallet to hold the wallet, and it is never cleared, so after a release the registry still names
/// the previous holder while that holder's own mapping reads false. The direction that does hold is
/// the one that matters: a device wallet that currently holds an eSIM wallet is the device wallet
/// the registry names.
///
/// Two of the three addresses are linked in the conf rather than merely required to match:
/// `DeviceWallet.registry` to the registry in the scene and `ESIMWallet.deviceWallet` to the device
/// wallet. A `require` fixes what an address equals, which is not the same as making the call at
/// that address run the callee's code, and without the link `bindESIMWallet` is summarised and the
/// registry side of every rule below is arbitrary.
///
/// Scope. Calls out of the three contracts, into the two factories, the beacon and the entry point,
/// are still summarised as NONDET, so nothing here is a statement about re-entrancy. One consequence
/// worth naming: `deployESIMWallet` gets the address of the new wallet back from a summarised
/// factory, so the prover may hand it any address, this scene's eSIM wallet included. That is the
/// conservative direction and the add path checks ownership either way. The curve check
/// on an owner key is summarised for the same reason as in the other specs: it is field arithmetic
/// no rule reads an answer from. Loops unroll three times and hashing of unbounded arguments is
/// assumed within 224 bytes.
///
/// A call leaving the scene is the one thing this spec has to be careful about, and the other specs
/// in this directory do not. They verify one contract, so a call out of it is havoced everywhere
/// else and the rule never notices. Here the rules read three contracts, so a havoc scoped to
/// everything except the caller rewrites the two a rule reads but does not call, and the assert
/// fails for a reason that exists only in the model. The methods block names every such signature
/// so none of them is left to the prover's own choice, and the conf assumes an unresolved
/// contract's fallback has no side effects for the same reason.
///
/// Reading the result, which the headline count gets backwards. `rule_sanity` appends `assert false`
/// to each rule and the log carries the verdict of that modified rule, not a verdict on the check.
/// `Violated: <rule>-<method>-rule_not_vacuous` means the body was reachable, which is the outcome
/// wanted. A `rule_not_vacuous` record reading verified is the failure. Count the records carrying
/// no sanity suffix and ignore the fraction.

using DeviceWallet as deviceWallet;
using ESIMWallet as eSIMWallet;

methods {
    function isESIMWalletValid(address) external returns (address) envfree;
    function isESIMWalletOnStandby(address) external returns (bool) envfree;
    function isDeviceWalletValid(address) external returns (bool) envfree;

    function deviceWallet.isValidESIMWallet(address) external returns (bool) envfree;
    function deviceWallet.registry() external returns (address) envfree;

    function eSIMWallet.owner() external returns (address) envfree;
    function eSIMWallet.newRequestedOwner() external returns (address) envfree;
    function eSIMWallet.deviceWallet() external returns (address) envfree;

    /// The calls between these three contracts run real code, and nothing else does.
    ///
    /// The other specs in this directory summarise every external call, which is right when a rule
    /// reads one contract's storage and nothing else. Here it is wrong: the calls between these
    /// three are the whole subject, and a summarised call is havoced everywhere except the contract
    /// under verification, so a summarised `bindESIMWallet` would leave the registry side of every
    /// rule arbitrary. The first run of this spec did exactly that and every method containing an
    /// external call failed while every view method passed.
    ///
    /// Resolution is per signature rather than per contract, and the difference is not cosmetic. A
    /// list naming whole contracts applies to every unresolved call in the scene, so the call to the
    /// entry point inside `addDeposit` becomes a candidate for resolution into one of these three,
    /// and a method that touches none of this storage fails anyway. That is what the second run
    /// reported. Naming signatures means a call is resolved only where the callee really is one of
    /// these contracts, and everything else stays summarised.
    ///
    /// Each of the six is a call made on an address taken from a parameter rather than from storage.
    /// The two made through a storage field, `DeviceWallet.registry` and `ESIMWallet.deviceWallet`,
    /// need nothing here because the conf links them.
    function _.owner() external => DISPATCHER(true);
    function _.newRequestedOwner() external => DISPATCHER(true);
    function _.sendETHToDeviceWallet(uint256 amount) external => DISPATCHER(true);
    function _.setESIMUniqueIdentifier(string identifier) external => DISPATCHER(true);
    function _.addESIMWallet(address walletAddress, bool hasAccessToETH) external => DISPATCHER(true);
    function _.setESIMUniqueIdentifierForAnESIMWallet(address walletAddress, string identifier)
        external => DISPATCHER(true);
    function _.populateHistory(ESIMWallet.DataBundleDetails[] bundles) external => DISPATCHER(true);

    /// Every call that leaves the three contracts, named one signature at a time.
    ///
    /// The `unresolved external` line below does not reach these. It catches a call whose selector
    /// the prover cannot work out; here the selector is known and only the callee address is, since
    /// it comes from a storage field pointing at a contract outside the scene. The prover then picks
    /// its own summary, and the one it picks havocs every contract except the caller. That rewrites
    /// the two contracts a rule reads but does not call, so `addDeposit`, whose whole body is one
    /// entry point call, failed a rule about who owns an eSIM wallet. The call trace named it: an
    /// `AUTO havoc` on storage path `DeviceWallet.entryPoint`, scoped to everything except
    /// `DeviceWallet`.
    ///
    /// NONDET rather than a link because none of these four is part of the statement being proved.
    /// The entry point holds gas deposits and the factories hand back addresses, and a rule here
    /// reads neither. Handing back an arbitrary address is the conservative direction anyway: the
    /// add path checks ownership whatever address it is given.
    function _.balanceOf(address account) external => NONDET;
    function _.depositTo(address account) external => NONDET;
    function _.withdrawTo(address withdrawAddress, uint256 amount) external => NONDET;
    function _.deployESIMWallet(address deviceWalletAddress, uint256 salt) external => NONDET;
    function _.deployDeviceWalletForUsers(
        string[] deviceUniqueIdentifiers,
        bytes32[2][] ownerKeys,
        uint256[] salts,
        uint256[] depositAmounts
    ) external => NONDET;

    unresolved external in _._ => DISPATCH [] default NONDET;

    function FCL_Elliptic_ZZ.ecAff_isOnCurve(uint256 x, uint256 y) internal returns (bool) => NONDET;
}

/// The four initialisers, filtered out of every rule below.
///
/// Each writes the storage the rules are about, straight in, with no guard but the `initializer`
/// modifier. That is a state no deployment reaches: all three contracts are set up in the same
/// transaction that creates the proxy, with the initialiser passed as the constructor argument. The
/// prover disagrees because OpenZeppelin's `initializer` recognises a constructor by
/// `initialized == 1 && address(this).code.length == 0`, and the prover models these contracts as
/// carrying code, so it starts from an uninitialised wallet no proxy ever is.
definition isInitialiser(method f) returns bool =
    f.selector == sig:DeviceWallet.init(address, bytes32[2], string, address).selector
 || f.selector == sig:DeviceWallet.initialize(bytes32[2]).selector
 || f.selector == sig:ESIMWallet.initialize(address, address).selector
 || f.selector == sig:Registry.initialize(address, address, address, address, address, address).selector;

/// The three instances in the scene are wired to each other.
///
/// Without this the prover is free to hand back a device wallet pointing at some other registry, or
/// a registry that has never heard of the device wallet, and every rule below fails on a triple that
/// no deployment produces. The device wallet's registry address is written once at `init` and the
/// registry flag is set when the factory reports the deployment, so both are facts about any wallet
/// that reached the protocol at all.
function requireLinkedScene() {
    require deviceWallet.registry() == currentContract;
    require isDeviceWalletValid(deviceWallet);
    require deviceWallet != eSIMWallet;
    require deviceWallet != currentContract;
    require eSIMWallet != currentContract;
}

/// An outstanding transfer request means the holder has already let go.
///
/// Proved first because the three rules below carry it as a precondition, and it is the fact that
/// makes `acceptOwnershipTransfer` safe. That function moves `owner()` to the requested address
/// without consulting either wallet's mapping, so if a device wallet could still be holding the
/// eSIM wallet while a request stood, acceptance would hand ownership away from underneath it.
///
/// What rules that out is the order inside `requestTransferOwnership`: it calls `removeESIMWallet`
/// on the current holder before it writes `newRequestedOwner`, so the flag is already down by the
/// time the request exists. The revoke path writes zero and touches no mapping, and the re-add path
/// runs after acceptance has cleared the request, so neither reopens the gap.
rule aTransferRequestMeansTheHolderHasAlreadyLetGo(method f) filtered { f -> !isInitialiser(f) } {
    requireLinkedScene();
    require eSIMWallet.newRequestedOwner() != 0 => !deviceWallet.isValidESIMWallet(eSIMWallet);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert eSIMWallet.newRequestedOwner() != 0 => !deviceWallet.isValidESIMWallet(eSIMWallet),
        "a transfer was requested while the device wallet still held the eSIM wallet";
}

/// A device wallet that holds an eSIM wallet is the owner of it.
///
/// This is the precondition the registry rule below needs, and it is worth proving on its own: it is
/// the fact that keeps the two ownership records from drifting. `_addESIMWallet` refuses a wallet
/// whose `owner()` is not the calling device wallet, and ownership only moves through
/// `requestTransferOwnership`, which calls `removeESIMWallet` on the current holder before it writes
/// anything. So the holding flag and the ownership always move in the same call.
///
/// Stated as a transition rule rather than an invariant for the same reason as everywhere else in
/// this directory: these contracts sit behind beacon proxies and are set up in an initialiser rather
/// than a constructor, so an invariant's base case would be arguing about a state the proxy never
/// occupies.
rule aHeldESIMWalletIsOwnedByTheDeviceWalletHoldingIt(method f) filtered { f -> !isInitialiser(f) } {
    requireLinkedScene();
    require deviceWallet.isValidESIMWallet(eSIMWallet) => eSIMWallet.owner() == deviceWallet;

    /// Carried from the rule above rather than assumed. `acceptOwnershipTransfer` moves `owner()`
    /// with no reference to either mapping, so without this it lands on a state where the device
    /// wallet is still holding a wallet whose ownership has just moved. That state is unreachable
    /// and the rule above is what says so.
    require eSIMWallet.newRequestedOwner() != 0 => !deviceWallet.isValidESIMWallet(eSIMWallet);

    /// The zero address cannot originate a call. Without this the prover accepts an ownership
    /// transfer requested of nobody: `acceptOwnershipTransfer` compares `msg.sender` against
    /// `newRequestedOwner` and both being zero passes, which walks the eSIM wallet's owner to zero
    /// while the device wallet still holds it. Nothing on chain reaches that, so a zero-check on the
    /// accept path would defend against nothing. The same artifact shows up on `Ownable2Step` in the
    /// factory spec.
    env callEnv;
    require callEnv.msg.sender != 0;

    calldataarg args;
    f(callEnv, args);

    assert deviceWallet.isValidESIMWallet(eSIMWallet) => eSIMWallet.owner() == deviceWallet,
        "a device wallet held an eSIM wallet it does not own";
}

/// The registry names the device wallet that currently holds an eSIM wallet.
///
/// The point of the whole spec. `isValidESIMWallet` on the device wallet is what every ETH path
/// checks; `isESIMWalletValid` on the registry is what the rest of the protocol reads to decide
/// whether an eSIM wallet belongs to anyone. If the two disagree, an eSIM wallet is being spent
/// against by one device wallet while the registry attributes it to another.
///
/// Only one direction is asserted, and the reverse is not an omission. The registry entry is a
/// permanent registration that also names the last holder, so after `removeESIMWallet` it still
/// names the previous device wallet while that wallet's own flag has already gone down. That gap is
/// the transfer window and it is intended.
///
/// The rule carries the ownership fact above as a precondition rather than restating it, which is
/// what makes the binding guard readable: `bindESIMWallet` accepts a caller that either owns the
/// eSIM wallet or is already the associated device wallet, and the precondition is what rules out a
/// second device wallet satisfying the first of those while this one still holds the wallet.
///
/// What is not covered, stated plainly. The scene has one device wallet, so a second device wallet
/// calling `bindESIMWallet` is modelled as an arbitrary address rather than as a real instance. Its
/// call still has to get past the same two guards, both of which read storage that is in the scene,
/// so the guard itself is exercised; what is missing is any statement about that second wallet's own
/// mapping. Covering it needs two device wallet instances, which doubles the parametric instances
/// for a fact the first rule already fixes on each of them separately.
rule theRegistryNamesTheDeviceWalletThatHoldsTheESIMWallet(method f) filtered { f -> !isInitialiser(f) } {
    requireLinkedScene();
    require deviceWallet.isValidESIMWallet(eSIMWallet) => eSIMWallet.owner() == deviceWallet;
    require deviceWallet.isValidESIMWallet(eSIMWallet) =>
        isESIMWalletValid(eSIMWallet) == deviceWallet;

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert deviceWallet.isValidESIMWallet(eSIMWallet) =>
        isESIMWalletValid(eSIMWallet) == deviceWallet,
        "the registry named a different device wallet than the one holding the eSIM wallet";
}

/// Releasing an eSIM wallet moves both records in one call.
///
/// The release is the one operation that writes a mapping in each contract, and it writes them
/// through two different contracts in one transaction: the device wallet lowers its own holding flag
/// and then calls the registry to raise the transit marker. Either write landing without the other
/// is a wallet that reads as held by nobody with no transfer outstanding, or as in transit while its
/// holder still spends against it.
///
/// This began as a parametric rule saying a held wallet is never on the marker, and the prover was
/// right to refuse it. `toggleESIMWalletStandbyStatus` is public and asks only that the caller is
/// the associated device wallet, so a holder can raise the marker on a wallet it has not released.
/// The natspec on that function says the same thing in words. A parametric rule forbidding the pair
/// would have been a rule about a design the protocol does not have, which is the mistake the
/// association rules already made once.
///
/// Stated as a direct call rather than parametrically, because the claim is about one operation
/// being atomic across two contracts and not about every method preserving something.
rule releasingAnESIMWalletMovesBothRecordsTogether(address wallet, bool callBackETH) {
    requireLinkedScene();

    env callEnv;
    deviceWallet.removeESIMWallet(callEnv, wallet, callBackETH);

    assert !deviceWallet.isValidESIMWallet(wallet),
        "a released eSIM wallet was still held by the device wallet";
    assert isESIMWalletOnStandby(wallet),
        "a released eSIM wallet was not put on the transit marker";
}
