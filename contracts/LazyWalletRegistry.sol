// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {Errors} from "./Errors.sol";

// Types
import {DataBundleDetails} from "./CustomStructs.sol";

// Contracts
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Registry} from "./Registry.sol";

/// @notice Holds what a fiat user bought before they had a wallet, then deploys the wallets and
///         copies the record onto them
/// @dev Everything here is keyed by string identifiers rather than by address, because a lazy user
///      has no address yet. Deployment and the history copy are both batched and both carry their
///      own cursor in storage, so a dropped transaction is retried by repeating the same call. Each
///      batch loop reverts on its terminal condition rather than returning quietly, which is what
///      lets a caller loop until it stops.
contract LazyWalletRegistry is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {

    /// @notice Longest device or eSIM identifier accepted when a new binding is created
    /// @dev An eSIM identifier is a UUID v4 in string form, so 36 bytes. This leaves room for a
    ///      longer device identifier while keeping both inside two storage words, which bounds the
    ///      keccak cost of the linear scan the switch path runs over the whole list.
    uint256 private constant MAX_IDENTIFIER_LENGTH = 64;

    /// @notice Most purchase history entries `setHistoryForLazyWallet` will copy in one call
    /// @dev Each entry costs roughly 50,000 gas to write into the wallet, so a full batch is around
    ///      2,500,000. The limit is about keeping a failed batch cheap to retry rather than about
    ///      the block limit, which is 30,000,000 at its tightest across the deployment chains.
    ///      Refused rather than clamped, so a caller never believes it wrote more than it did.
    uint256 public constant MAX_HISTORY_ENTRIES_PER_CALL = 50;

    /// @notice Most eSIM wallets a single call will deploy for one device
    /// @dev A deployment costs roughly 450,000 gas per eSIM wallet, so a full batch is around
    ///      9,000,000. As with the history cap this is set for retry cost rather than the block
    ///      limit: a batch that runs out of gas is paid for and thrown away, and a device with forty
    ///      eSIMs should not lose a whole block's worth of gas to one bad estimate. It also leaves
    ///      room for `forge coverage --ir-minimum`, which inflates the same call by about a fifth.
    ///      Refused rather than clamped, so a caller never believes it deployed more than it did.
    uint256 public constant MAX_ESIM_WALLETS_PER_CALL = 20;

    /// @dev Slot that used to hold a copy of the upgrade authority. It was written once in
    ///      `initialize` and had no setter, so it kept naming the deploy-time address once
    ///      ownership moved on. Kept so nothing below it shifts on the live proxies. Never read;
    ///      `upgradeManager()` returns `owner()` instead.
    ///
    ///      Slither raises `unused-state` and `constable-states` here. Both are false: occupying
    ///      the slot is the whole job, and either change takes it out of storage and moves every
    ///      variable below it.
    address private _retiredUpgradeManager;

    /// @notice Registry contract instance
    Registry public registry;

    /// @notice eSIM identifiers and their details associated with the device identifiers
    mapping(string deviceIdentifier => mapping(string eSIMIdentifier => DataBundleDetails[] dataBundleDetails)) public deviceIdentifierToESIMDetails;

    /// @notice Mapping from eSIM unique identifier to device unique identifier
    /// @dev A device identifier can have multiple associated eSIM identifiers.
    /// But an eSIM identifier can have only a single device identifier.
    mapping(string eSIMIdentifier => string deviceIdentifier) public eSIMIdentifierToDeviceIdentifier;

    /// @notice List of eSIM identifiers associated with the device identifiers
    mapping(string deviceIdentifier => string[] associatedESIMIdentifiers) public eSIMIdentifiersAssociatedWithDeviceIdentifier;

    /// @notice How many of an eSIM's stored purchase entries have already reached its wallet
    /// @dev The wallet appends whatever batch it is handed, so this is the only thing stopping a
    ///      repeated call from writing the same entries twice. Reading it rather than taking start
    ///      and end indexes from the caller also makes two admin transactions in flight at once
    ///      safe: the second reads the position the first left.
    mapping(string eSIMIdentifier => uint256 copied) public historyEntriesCopied;

    /// @notice The eSIM wallet this contract deployed for an eSIM identifier
    /// @dev Nothing enforces that an eSIM identifier is unique across eSIM wallets, so without this
    ///      record a wallet deployed through the ordinary route could claim an identifier that
    ///      already belongs to a lazy user and receive their purchase history. Written from the
    ///      addresses the deployment returns, and unaffected by any later ownership transfer, so
    ///      the copy follows the wallet rather than whichever device is holding it.
    mapping(string eSIMIdentifier => address eSIMWallet) public lazyDeployedESIMWallet;

    /// @notice How many of a device's eSIM wallets this contract has already deployed
    /// @dev Also the marker for the lazy route itself. The first batch always deploys at least one
    ///      wallet, so a non-zero value means this contract set the device up. Reading the registry
    ///      for a device wallet instead would accept one deployed through the ordinary route under
    ///      an identifier a lazy user's eSIMs are already bound to, and hand that device their
    ///      wallets.
    mapping(string deviceIdentifier => uint256 deployed) public eSIMWalletsDeployed;

    /// @notice Salt the device's first deployment batch started from
    /// @dev Every later batch derives its salts from this, so the sequence continues rather than
    ///      restarting on an address that already holds a wallet. Stored rather than taken from the
    ///      caller again, because a value that disagrees with the first batch is not something the
    ///      contract can detect: it just produces different addresses.
    mapping(string deviceIdentifier => uint256 baseSalt) public lazyDeploymentSalt;

    /// @notice Emitted when data related to a device is updated
    event DataUpdatedForDevice(
        string _deviceUniqueIdentifier, string[] _eSIMUniqueIdentifiers, DataBundleDetails[] _dataBundleDetails
    );

    /// @notice Emitted when an eSIM identifier is associated with a device identifier
    event ESIMBindedWithDevice(string _eSIMUniqueIdentifier, string _deviceUniqueIdentifier);

    /// @notice Emitted when the Lazy wallet is deployed
    /// @dev The device wallet is indexed so an indexer can follow one device without reading every
    ///      log. The two string arrays are left unindexed on purpose: indexing a dynamic type stores
    ///      its hash instead of its value, which no consumer of these can use.
    event LazyWalletDeployed(
        bytes32[2] _deviceOwnerPublicKey,
        address indexed deviceWallet,
        string _deviceUniqueIdentifier,
        address[] eSIMWallets,
        string[] _eSIMUniqueIdentifiers
    );

    /// @notice Emitted for every batch of eSIM wallets deployed for a device, including the first.
    ///         `_remaining` reaching zero is what says the device is fully deployed.
    /// @dev `LazyWalletDeployed` fires once, when the device wallet itself is created, and carries
    ///      only the first batch. Anything waiting for the whole set has to follow this instead.
    event LazyESIMWalletsDeployed(
        string _deviceUniqueIdentifier,
        address indexed _deviceWallet,
        address[] _eSIMWallets,
        string[] _eSIMUniqueIdentifiers,
        uint256 _remaining
    );

    /// @notice Emitted for every batch of purchase history copied into a deployed eSIM wallet.
    ///         `_remaining` reaching zero is what says the copy is finished.
    event LazyHistoryCopied(
        string _eSIMIdentifier,
        address indexed _eSIMWallet,
        uint256 _copied,
        uint256 _remaining
    );

    /// @notice Emitted when the user switches eSIM to a new device
    event ESIMIdentifierSwitchedToNewDeviceIdentifier(
        string _eSIMIdentifier,
        string _oldDeviceIdentifier,
        string currentDeviceIdentifier
    );

    /// @notice Emitted when the device identifier associated with an eSIM identifier is updated
    event NewDeviceIdentifierAssociatedWithESIMIdentifier(
        string _eSIMIdentifier,
        string _oldDeviceIdentifier,
        string _newDeviceIdentifier);

    /// @notice Emitted when the Data bundle related details of an eSIM are transferred to a new device identifier
    event DataBundleDetailsTransferredToNewDeviceIdentifier(
        string _newDeviceIdentifier,
        DataBundleDetails[] _newDataBundleDetails
    );

    /// @notice Emitted when the data bundle details are deleted from the old device identifier
    event DataBundleDetailsDeletedFromOldDeviceIdentifier(
        string _oldDeviceIdentifier,
        string _eSIMIdentifier
    );

    /// @notice Emitted when an eSIM identifier is removed from a device identifier's list
    event ESIMIdentifierRemovedFromOldDeviceIdentifier(
        string _oldDeviceIdentifier,
        string _eSIMIdentifier,
        string[] _eSIMIdentifierOfOldDevice
    );

    /// @notice Emitted when an eSIM identifier is added to a new device identifier's list
    event ESIMIdentifierAddedToNewDeviceIdentifier(
        string _newDeviceIdentifier,
        string _eSIMIdentifier,
        string[] _eSIMIdentifierOfNewDevice
    );

    /// @notice Restricts a call to the eSIM wallet admin
    /// @dev Read from the registry on every call, so a rotation there takes effect immediately.
    ///      Every state-changing function in this contract sits behind it.
    modifier onlyESIMWalletAdmin() {
        if(msg.sender != registry.eSIMWalletAdmin()) revert Errors.OnlyESIMWalletAdmin();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @dev Locks the implementation contract itself. Without this, anyone can call initialize
    ///      directly on the implementation and own it. The proxy is unaffected either way, but an
    ///      owned implementation is a trap for any later upgrade that adds an outward call.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Points this contract at the registry and hands ownership to the upgrade manager
    /// @param _registry Registry this contract reads the admin from and deploys wallets through
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    function initialize(
        address _registry,
        address _upgradeManager
    ) external initializer {
        if(_registry == address(0)) revert Errors.ZeroAddress("_registry");
        if(_upgradeManager == address(0)) revert Errors.ZeroAddress("_upgradeManager");

        registry = Registry(_registry);

        __Ownable2Step_init();
        __Ownable_init(_upgradeManager);
    }

    // ---------------------------------------------------------------------------------------------
    // Recording purchases made before deployment
    // ---------------------------------------------------------------------------------------------

    /// @notice Function to populate all the device and eSIM related data along with the data bundles
    /// @dev Refused for any device that already has a wallet, which is what freezes a device's eSIM
    ///      list and its history for the whole time a deployment is walking them.
    /// @param _deviceUniqueIdentifiers List of device unique identifiers associated with the eSIM related data
    /// @param _eSIMUniqueIdentifiers 2D array of all the eSIMs corresponding to their device identifiers.
    /// @param _dataBundleDetails 2D array of all the new data bundles bought for the respective eSIMs
    function batchPopulateHistory(
        string[] calldata _deviceUniqueIdentifiers,
        string[][] calldata _eSIMUniqueIdentifiers,
        DataBundleDetails[][] calldata _dataBundleDetails
    ) external onlyESIMWalletAdmin {
        uint256 len = _deviceUniqueIdentifiers.length;
        if(len != _eSIMUniqueIdentifiers.length) {
            revert Errors.ArrayLengthMismatch(len, _eSIMUniqueIdentifiers.length);
        }
        if(len != _dataBundleDetails.length) {
            revert Errors.ArrayLengthMismatch(len, _dataBundleDetails.length);
        }

        for(uint256 i=0; i<len; ++i) {
            _populateHistory(_deviceUniqueIdentifiers[i], _eSIMUniqueIdentifiers[i], _dataBundleDetails[i]);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Lazy deployment
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys a device wallet and the first batch of its eSIM wallets, setting their identifiers
    /// @dev Only the first `_maxWallets` eSIM wallets are deployed here. Anything left goes through
    ///      `deployMoreESIMWalletsForLazyDevice`, because one transaction carrying every wallet grew
    ///      without bound with the eSIM count and stopped fitting in a block somewhere past forty.
    ///
    ///      The device wallet is usable the moment this returns. Its eSIM wallets are complete and
    ///      independent of each other, so holding it back until the last one lands would mean one
    ///      dropped transaction leaves the user with nothing rather than with most of what they
    ///      bought. Switching an eSIM to another device is refused for the whole time the rest are
    ///      outstanding, which `switchESIMIdentifierToNewDeviceIdentifier` already does by refusing
    ///      any device that has a wallet.
    /// @param _deviceOwnerPublicKey P256 public key of the device owner
    /// @param _deviceUniqueIdentifier Unique device identifier associated with the device
    /// @param _salt Salt the whole deployment derives its eSIM wallet addresses from
    /// @param _depositAmount Amount of ETH to be deposited in the device wallet
    /// @param _maxWallets Most eSIM wallets to deploy here, at most MAX_ESIM_WALLETS_PER_CALL
    /// @return deviceWallet Address of the deployed device wallet
    /// @return eSIMWallets eSIM wallets this call deployed, in the order of the device's identifiers
    /// @return remaining eSIM wallets still waiting after this call
    function deployLazyWalletAndSetESIMIdentifier(
        bytes32[2] memory _deviceOwnerPublicKey,
        string calldata _deviceUniqueIdentifier,
        uint256 _salt,
        uint256 _depositAmount,
        uint256 _maxWallets
    ) external payable onlyESIMWalletAdmin returns (
        address deviceWallet,
        address[] memory eSIMWallets,
        uint256 remaining
    ) {
        if(_depositAmount != msg.value) revert Errors.DepositDoesNotMatchValue(_depositAmount, msg.value);
        if(isLazyWalletDeployed(_deviceUniqueIdentifier)) {
            revert Errors.LazyWalletAlreadyDeployed(_deviceUniqueIdentifier);
        }

        string[] storage allESIMIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
        uint256 total = allESIMIdentifiers.length;
        if(total == 0) revert Errors.NoESIMIdentifiersForDevice(_deviceUniqueIdentifier);

        // The whole salt range is reserved here rather than one batch at a time, because every later
        // batch continues from this salt. A range that overflows partway would leave a device that
        // cannot be finished and cannot be redeployed either.
        if(total + _salt >= type(uint256).max) revert Errors.SaltTooHigh(_salt, total);

        uint256 batchSize = _boundedBatchSize(_maxWallets, total);
        string[] memory batchIdentifiers = _readIdentifiers(allESIMIdentifiers, 0, batchSize);

        // Both cursors move before the deployment, the same way the history copy advances its own
        // ahead of handing a batch to the wallet. Nothing can currently reach back in mid-batch,
        // since every callee is a protocol contract and this is admin gated, but eSIM wallets share
        // one beacon and a later implementation is free to do more during initialisation.
        lazyDeploymentSalt[_deviceUniqueIdentifier] = _salt;
        eSIMWalletsDeployed[_deviceUniqueIdentifier] = batchSize;

        (deviceWallet, eSIMWallets) = registry.deployLazyWallet{value: msg.value}(
            _deviceOwnerPublicKey,
            _deviceUniqueIdentifier,
            _salt,
            batchIdentifiers,
            _depositAmount
        );

        _recordDeployedESIMWallets(batchIdentifiers, eSIMWallets);

        remaining = total - batchSize;

        emit LazyWalletDeployed(
            _deviceOwnerPublicKey,
            deviceWallet,
            _deviceUniqueIdentifier,
            eSIMWallets,
            batchIdentifiers
        );
        emit LazyESIMWalletsDeployed(
            _deviceUniqueIdentifier,
            deviceWallet,
            eSIMWallets,
            batchIdentifiers,
            remaining
        );
    }

    /// @notice Deploys the next batch of eSIM wallets for a device already set up by the lazy route
    /// @dev Call it repeatedly until it reverts `AllESIMWalletsDeployed`, which is the terminal
    ///      condition rather than a failure. Reverting instead of returning quietly is what lets a
    ///      caller loop on it. The cursor is read here rather than taken as an argument, so a
    ///      dropped transaction is retried by repeating the same call.
    ///
    ///      No pause check and no deposit. This moves no ETH, and the identifier list it walks was
    ///      frozen when the device wallet appeared: `_populateHistory` refuses a device that already
    ///      has one, so nothing can be appended to the list under a running deployment.
    /// @param _deviceUniqueIdentifier Device whose remaining eSIM wallets are being deployed
    /// @param _maxWallets Most eSIM wallets to deploy here, at most MAX_ESIM_WALLETS_PER_CALL
    /// @return eSIMWallets eSIM wallets this call deployed, in the order of the device's identifiers
    /// @return remaining eSIM wallets still waiting after this call
    function deployMoreESIMWalletsForLazyDevice(
        string calldata _deviceUniqueIdentifier,
        uint256 _maxWallets
    ) external onlyESIMWalletAdmin returns (address[] memory eSIMWallets, uint256 remaining) {
        uint256 alreadyDeployed = eSIMWalletsDeployed[_deviceUniqueIdentifier];
        // Non-zero exactly when this contract ran the first batch, since that batch always deploys
        // at least one wallet. Asking the registry for a device wallet instead would also accept one
        // deployed through the ordinary route under this identifier, and bind a lazy user's eSIM
        // wallets, and later their purchase history, to a device that is not theirs.
        if(alreadyDeployed == 0) revert Errors.LazyWalletNotDeployed(_deviceUniqueIdentifier);

        string[] storage allESIMIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
        uint256 outstanding = allESIMIdentifiers.length - alreadyDeployed;
        if(outstanding == 0) revert Errors.AllESIMWalletsDeployed(_deviceUniqueIdentifier);

        uint256 batchSize = _boundedBatchSize(_maxWallets, outstanding);
        string[] memory batchIdentifiers = _readIdentifiers(allESIMIdentifiers, alreadyDeployed, batchSize);

        address deviceWallet = registry.uniqueIdentifierToDeviceWallet(_deviceUniqueIdentifier);

        // Moved before the deployment for the same reason as in the first batch. It also means a
        // reentrant call would find the cursor already past this batch rather than deploying the
        // same positions twice.
        eSIMWalletsDeployed[_deviceUniqueIdentifier] = alreadyDeployed + batchSize;

        eSIMWallets = registry.deployMoreLazyESIMWallets(
            deviceWallet,
            _deviceUniqueIdentifier,
            lazyDeploymentSalt[_deviceUniqueIdentifier],
            alreadyDeployed,
            batchIdentifiers
        );

        _recordDeployedESIMWallets(batchIdentifiers, eSIMWallets);

        remaining = outstanding - batchSize;

        emit LazyESIMWalletsDeployed(
            _deviceUniqueIdentifier,
            deviceWallet,
            eSIMWallets,
            batchIdentifiers,
            remaining
        );
    }

    /// @notice Copies the next batch of an eSIM's stored purchase history into its deployed wallet
    /// @dev Split out of the deployment because carrying history there made one transaction grow
    ///      with the eSIM count and the history length at the same time. Call it repeatedly until
    ///      it reverts `HistoryAlreadyCopied`, which is the terminal condition rather than a
    ///      failure. Reverting instead of returning quietly is what lets a caller loop on it.
    ///
    ///      No pause check. This moves no ETH, and the entries it writes were frozen when the
    ///      wallet was deployed: `_populateHistory` refuses a device that already has one.
    /// @param _eSIMIdentifier eSIM whose history is being copied
    /// @param _maxEntries Most entries to copy in this call, at most MAX_HISTORY_ENTRIES_PER_CALL
    /// @return copied Entries written by this call
    /// @return remaining Entries still waiting after this call
    function setHistoryForLazyWallet(
        string calldata _eSIMIdentifier,
        uint256 _maxEntries
    ) external onlyESIMWalletAdmin returns (uint256 copied, uint256 remaining) {
        if(_maxEntries == 0 || _maxEntries > MAX_HISTORY_ENTRIES_PER_CALL) {
            revert Errors.TooManyHistoryEntries(_maxEntries, MAX_HISTORY_ENTRIES_PER_CALL);
        }

        // This lookup is the whole authorisation. An identifier only has an entry here if this
        // contract deployed a wallet for it, so history cannot be aimed at a wallet somebody else
        // created under the same identifier.
        address eSIMWallet = lazyDeployedESIMWallet[_eSIMIdentifier];
        if(eSIMWallet == address(0)) revert Errors.ESIMWalletNotLazyDeployed(_eSIMIdentifier);

        string memory deviceIdentifier = eSIMIdentifierToDeviceIdentifier[_eSIMIdentifier];
        DataBundleDetails[] storage history = deviceIdentifierToESIMDetails[deviceIdentifier][_eSIMIdentifier];

        uint256 alreadyCopied = historyEntriesCopied[_eSIMIdentifier];
        uint256 outstanding = history.length - alreadyCopied;
        if(outstanding == 0) revert Errors.HistoryAlreadyCopied(_eSIMIdentifier);

        copied = outstanding > _maxEntries ? _maxEntries : outstanding;
        remaining = outstanding - copied;

        DataBundleDetails[] memory batch = new DataBundleDetails[](copied);
        for(uint256 i=0; i<copied; ++i) {
            batch[i] = history[alreadyCopied + i];
        }

        historyEntriesCopied[_eSIMIdentifier] = alreadyCopied + copied;

        registry.populateLazyHistory(eSIMWallet, batch);

        emit LazyHistoryCopied(_eSIMIdentifier, eSIMWallet, copied, remaining);
    }

    // ---------------------------------------------------------------------------------------------
    // Switching an eSIM to another device
    // ---------------------------------------------------------------------------------------------

    /// @notice This function should be called when the fiat user wants to switch their eSIM to a new device
    /// @dev Only ever before deployment. Once a wallet exists onchain, the onchain graph is the
    ///      record and the eSIM moves through ESIMWallet's ownership transfer instead.
    /// @param _eSIMIdentifier unique eSIM identifier that needs to be switched to a new device
    /// @param _oldDeviceIdentifier device identifier that the eSIM is currently associated with
    /// @param _newDeviceIdentifier new device identifier that the eSIM needs to be switched to
    /// @return bool Returns `true` if the switching of eSIM was successful
    function switchESIMIdentifierToNewDeviceIdentifier(
        string calldata _eSIMIdentifier,
        string calldata _oldDeviceIdentifier,
        string calldata _newDeviceIdentifier
    ) external onlyESIMWalletAdmin returns (bool) {
        if(bytes(_eSIMIdentifier).length == 0) revert Errors.EmptyESIMIdentifier();
        if(bytes(_newDeviceIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();
        // Only the incoming device identifier is bounded. Bounding the eSIM identifier too would
        // block moving an over-length one off a device, which is how a device that predates this
        // limit gets unwound.
        _requireBoundedIdentifier(_newDeviceIdentifier);

        string memory currentDeviceIdentifier = eSIMIdentifierToDeviceIdentifier[_eSIMIdentifier];
        if(bytes(currentDeviceIdentifier).length == 0) revert Errors.UnknownESIMIdentifier(_eSIMIdentifier);
        // The length check is a cheap filter ahead of the hash, not a separate condition
        if(
            bytes(currentDeviceIdentifier).length != bytes(_oldDeviceIdentifier).length ||
            keccak256(bytes(currentDeviceIdentifier)) != keccak256(bytes(_oldDeviceIdentifier))
        ) {
            revert Errors.ESIMBoundToADifferentDevice(_eSIMIdentifier, currentDeviceIdentifier);
        }
        if(keccak256(bytes(_newDeviceIdentifier)) == keccak256(bytes(currentDeviceIdentifier))) {
            revert Errors.CannotSwitchToTheSameDevice(currentDeviceIdentifier);
        }
        // Once a wallet exists onchain, the onchain graph is the authoritative record of which eSIM
        // belongs to which device, and nothing here reads back into it. Switching the old device
        // would leave the deployed eSIM wallet owned by it while deleting its purchase history.
        // Switching to a deployed new device orphans the eSIM, because deploying that device again
        // is already refused. Post-deployment movement belongs to ESIMWallet's ownership transfer.
        //
        // This is also what closes the window while a deployment is still running. The first batch
        // creates the device wallet, so both checks below start refusing from that point rather than
        // from the last batch, and no eSIM can move out from under a cursor walking its list.
        if(isLazyWalletDeployed(_oldDeviceIdentifier)) {
            revert Errors.LazyWalletAlreadyDeployed(_oldDeviceIdentifier);
        }
        if(isLazyWalletDeployed(_newDeviceIdentifier)) {
            revert Errors.LazyWalletAlreadyDeployed(_newDeviceIdentifier);
        }

        eSIMIdentifierToDeviceIdentifier[_eSIMIdentifier] = _newDeviceIdentifier;
        emit NewDeviceIdentifierAssociatedWithESIMIdentifier(_eSIMIdentifier, currentDeviceIdentifier, _newDeviceIdentifier);

        _updateDeviceIdentifierToESIMDetails(_eSIMIdentifier, _oldDeviceIdentifier, _newDeviceIdentifier);
        _updateESIMIdentifiersAssociatedWithDeviceIdentifier(_eSIMIdentifier, _oldDeviceIdentifier, _newDeviceIdentifier);

        emit ESIMIdentifierSwitchedToNewDeviceIdentifier(_eSIMIdentifier, _oldDeviceIdentifier, currentDeviceIdentifier);

        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Ownership and upgrades
    // ---------------------------------------------------------------------------------------------

    /// @notice Ownership of this contract is never renounced
    /// @dev The owner is the only caller _authorizeUpgrade accepts, and there is no other route to
    ///      replace this implementation. Renouncing would freeze the contract on its current logic
    ///      permanently.
    function renounceOwnership() public pure override {
        revert Errors.OwnershipCannotBeRenounced();
    }

    /// @notice Restricts UUPS upgrades to the owner
    /// @param newImplementation Address of the implementation being moved to
    function _authorizeUpgrade(address newImplementation)
    internal
    onlyOwner
    override
    {}

    // ---------------------------------------------------------------------------------------------
    // History and device association
    // ---------------------------------------------------------------------------------------------

    /// @notice Records one device's eSIM identifiers and the purchases made against them
    /// @dev `_eSIMUniqueIdentifiers` may repeat an identifier, since one eSIM can have several
    ///      purchases. An identifier already bound to a different device is refused.
    /// @param _deviceUniqueIdentifier Device the purchases belong to
    /// @param _eSIMUniqueIdentifiers One entry per purchase, naming the eSIM it was made for
    /// @param _dataBundleDetails The purchases themselves, aligned with the identifiers
    function _populateHistory(
        string calldata _deviceUniqueIdentifier,
        string[] calldata _eSIMUniqueIdentifiers,
        DataBundleDetails[] calldata _dataBundleDetails
    ) internal {
        if(bytes(_deviceUniqueIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();
        _requireBoundedIdentifier(_deviceUniqueIdentifier);
        if(isLazyWalletDeployed(_deviceUniqueIdentifier)) {
            revert Errors.LazyWalletAlreadyDeployed(_deviceUniqueIdentifier);
        }

        uint256 len = _eSIMUniqueIdentifiers.length;
        if(len != _dataBundleDetails.length) {
            revert Errors.ArrayLengthMismatch(len, _dataBundleDetails.length);
        }

        for(uint256 i=0; i<len; ++i) {
            string calldata eSIMUniqueIdentifier = _eSIMUniqueIdentifiers[i];
            if(bytes(eSIMUniqueIdentifier).length == 0) revert Errors.EmptyESIMIdentifier();

            string memory deviceUniqueIdentifier = eSIMIdentifierToDeviceIdentifier[eSIMUniqueIdentifier];

            if(bytes(deviceUniqueIdentifier).length == 0) {
                _requireBoundedIdentifier(eSIMUniqueIdentifier);

                eSIMIdentifierToDeviceIdentifier[eSIMUniqueIdentifier] = _deviceUniqueIdentifier;

                string[] storage associatedESIMIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
                associatedESIMIdentifiers.push(eSIMUniqueIdentifier);

                emit ESIMBindedWithDevice(eSIMUniqueIdentifier, _deviceUniqueIdentifier);
            }
            else {
                if(keccak256(bytes(deviceUniqueIdentifier)) != keccak256(bytes(_deviceUniqueIdentifier))) {
                    revert Errors.ESIMBoundToADifferentDevice(eSIMUniqueIdentifier, deviceUniqueIdentifier);
                }
            }

            DataBundleDetails[] storage dataBundleDetails = deviceIdentifierToESIMDetails[_deviceUniqueIdentifier][eSIMUniqueIdentifier];
            // Manually add a new struct to history and then set its fields
            dataBundleDetails.push();  // Increase the array length by one
            DataBundleDetails storage newDataBundleDetail = dataBundleDetails[dataBundleDetails.length - 1];
            newDataBundleDetail.dataBundleID = _dataBundleDetails[i].dataBundleID;
            newDataBundleDetail.dataBundlePrice = _dataBundleDetails[i].dataBundlePrice;
        }

        emit DataUpdatedForDevice(_deviceUniqueIdentifier, _eSIMUniqueIdentifiers, _dataBundleDetails);
    }

    /// @notice Moves an eSIM's stored purchase history to the device taking it over
    /// @param _eSIMIdentifier eSIM being switched
    /// @param _oldDeviceIdentifier Device it is leaving
    /// @param _newDeviceIdentifier Device it is joining
    function _updateDeviceIdentifierToESIMDetails(
        string calldata _eSIMIdentifier,
        string calldata _oldDeviceIdentifier,
        string calldata _newDeviceIdentifier
    ) internal {
        DataBundleDetails[] storage dataBundleDetails = deviceIdentifierToESIMDetails[_oldDeviceIdentifier][_eSIMIdentifier];
        // Transfer history of the eSIM identifier to the new device identifier
        DataBundleDetails[] storage newDataBundleDetails = deviceIdentifierToESIMDetails[_newDeviceIdentifier][_eSIMIdentifier];
        // The two arrays are distinct because the caller refuses a switch to the same device, so
        // pushing onto one cannot lengthen the other and the bound can be read once.
        uint256 entries = dataBundleDetails.length;
        for(uint256 i=0; i<entries; ++i) {
            newDataBundleDetails.push(dataBundleDetails[i]);
        }
        emit DataBundleDetailsTransferredToNewDeviceIdentifier(_newDeviceIdentifier, newDataBundleDetails);

        // delete any reference of eSIM identifier from previous device identifier
        delete deviceIdentifierToESIMDetails[_oldDeviceIdentifier][_eSIMIdentifier];
        emit DataBundleDetailsDeletedFromOldDeviceIdentifier(_oldDeviceIdentifier, _eSIMIdentifier);
    }

    /// @notice Moves an eSIM identifier between the two devices' lists
    /// @dev The removal is a swap with the last element and a pop, so the old device's list keeps
    ///      its members but not their order.
    /// @param _eSIMIdentifier eSIM being switched
    /// @param _oldDeviceIdentifier Device it is leaving
    /// @param _newDeviceIdentifier Device it is joining
    function _updateESIMIdentifiersAssociatedWithDeviceIdentifier(
        string calldata _eSIMIdentifier,
        string calldata _oldDeviceIdentifier,
        string calldata _newDeviceIdentifier
    ) internal {
        // Remove eSIM identifier from previous device identifier
        string[] storage eSIMIdentifierOfOldDevice = eSIMIdentifiersAssociatedWithDeviceIdentifier[_oldDeviceIdentifier];

        uint256 i = 0;

        uint256 associated = eSIMIdentifierOfOldDevice.length;
        bytes32 target = keccak256(bytes(_eSIMIdentifier));

        for(; i<associated; ++i) {
            if(keccak256(bytes(eSIMIdentifierOfOldDevice[i])) == target) {
                break;
            }
        }
        if(i == associated) revert Errors.ESIMIdentifierNotFound(_eSIMIdentifier, _oldDeviceIdentifier);

        // Swap element to be removed with the element at the last index, and then pop last element
        eSIMIdentifierOfOldDevice[i] = eSIMIdentifierOfOldDevice[eSIMIdentifierOfOldDevice.length - 1];
        eSIMIdentifierOfOldDevice.pop();
        emit ESIMIdentifierRemovedFromOldDeviceIdentifier(_oldDeviceIdentifier, _eSIMIdentifier, eSIMIdentifierOfOldDevice);

        // Add eSIM identifier to new device identifier
        string[] storage eSIMIdentifierOfNewDevice = eSIMIdentifiersAssociatedWithDeviceIdentifier[_newDeviceIdentifier];
        eSIMIdentifierOfNewDevice.push(_eSIMIdentifier);
        emit ESIMIdentifierAddedToNewDeviceIdentifier(_newDeviceIdentifier, _eSIMIdentifier, eSIMIdentifierOfNewDevice);
    }

    // ---------------------------------------------------------------------------------------------
    // Batch bounds and records
    // ---------------------------------------------------------------------------------------------

    /// @notice Rejects a batch size outside the cap, then clamps it to what is actually left
    /// @dev A request above the cap is refused rather than clamped, so a caller never believes it
    ///      deployed more than it did. Clamping to the outstanding count is different: the caller
    ///      asked for more than exists, and the return value says how many it got.
    /// @param _requested Batch size the caller asked for
    /// @param _outstanding How many are actually left
    /// @return The batch size to use
    function _boundedBatchSize(uint256 _requested, uint256 _outstanding) private pure returns (uint256) {
        if(_requested == 0 || _requested > MAX_ESIM_WALLETS_PER_CALL) {
            revert Errors.TooManyESIMWallets(_requested, MAX_ESIM_WALLETS_PER_CALL);
        }

        return _requested > _outstanding ? _outstanding : _requested;
    }

    /// @notice Copies one batch of identifiers out of a device's list
    /// @dev Reads only the slice the batch needs. Copying the whole list into memory first would put
    ///      the cost this split exists to bound back into every call.
    /// @param _allESIMIdentifiers The device's full identifier list
    /// @param _startIndex Position this batch starts at
    /// @param _batchSize How many to read
    /// @return The batch's identifiers, in list order
    function _readIdentifiers(
        string[] storage _allESIMIdentifiers,
        uint256 _startIndex,
        uint256 _batchSize
    ) private view returns (string[] memory) {
        string[] memory batchIdentifiers = new string[](_batchSize);

        for(uint256 i=0; i<_batchSize; ++i) {
            batchIdentifiers[i] = _allESIMIdentifiers[_startIndex + i];
        }

        return batchIdentifiers;
    }

    /// @notice Binds each identifier in a batch to the wallet deployed for it
    /// @dev The deployment returns the wallets in the order it was given the identifiers, which is
    ///      what makes this pairing sound. It is the only proof later on that a wallet claiming an
    ///      eSIM identifier is the one this contract deployed for it. This cannot run before the
    ///      deployment, unlike the cursor, because the addresses do not exist until then.
    /// @param _batchIdentifiers The batch's eSIM identifiers
    /// @param _eSIMWallets The wallets deployed for them, in the same order
    function _recordDeployedESIMWallets(
        string[] memory _batchIdentifiers,
        address[] memory _eSIMWallets
    ) private {
        for(uint256 i=0; i<_batchIdentifiers.length; ++i) {
            lazyDeployedESIMWallet[_batchIdentifiers[i]] = _eSIMWallets[i];
        }
    }

    /// @notice Rejects an identifier longer than the protocol accepts
    /// @param _identifier Device or eSIM identifier about to create a new binding
    function _requireBoundedIdentifier(string calldata _identifier) private pure {
        if(bytes(_identifier).length > MAX_IDENTIFIER_LENGTH) {
            revert Errors.IdentifierTooLong(_identifier, MAX_IDENTIFIER_LENGTH);
        }
    }

    /// @notice Address (owned/controlled by eSIM wallet project) that can upgrade contracts
    /// @dev Reads through to the owner rather than holding its own copy. `_authorizeUpgrade` is
    ///      gated on `onlyOwner`, so the owner is the upgrade authority by definition and a second
    ///      copy could only ever disagree with it.
    function upgradeManager() public view returns (address) {
        return owner();
    }

    /// @notice Function to check if a lazy wallet has been deployed or not
    /// @dev Asks the registry for a device wallet, so it is also true for a device deployed through
    ///      the ordinary route. That is deliberate: both cases have to block a lazy deployment.
    /// @param _deviceUniqueIdentifier Device being checked
    /// @return Boolean. True if deployed, false otherwise
    function isLazyWalletDeployed(string calldata _deviceUniqueIdentifier) public view returns (bool) {
        if(registry.uniqueIdentifierToDeviceWallet(_deviceUniqueIdentifier) != address(0)) {
            return true;
        }

        return false;
    }
}
