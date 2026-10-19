// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {Errors} from "./Errors.sol";

// Types
import {DataBundleDetails, Settlement} from "./CustomStructs.sol";

// Contracts
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Registry} from "./Registry.sol";

/// @notice Holds what a fiat user bought before they had a wallet, then deploys the wallets and
///         copies the record onto them
/// @dev Keyed by string identifiers, since a lazy user has no address yet. Deployment and history
///      copy keep their cursors in storage, so a dropped transaction is retried by repeating it.
contract LazyWalletRegistry is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {

    /// @notice Longest device or eSIM identifier accepted when a new binding is created
    /// @dev An eSIM identifier is a 36-byte UUID. 64 keeps both kinds inside two storage words,
    ///      which bounds the hashing cost of the switch path's linear scan.
    uint256 private constant MAX_IDENTIFIER_LENGTH = 64;

    /// @notice Most purchase history entries `setHistoryForLazyWallet` will copy in one call
    /// @dev About 50,000 gas per entry, so a full batch is ~2,500,000: sized to keep a failed batch
    ///      cheap to retry, not for the block limit. Refused rather than clamped, so a caller never
    ///      believes it wrote more than it did.
    uint256 public constant MAX_HISTORY_ENTRIES_PER_CALL = 50;

    /// @notice Most eSIM wallets a single call will deploy for one device
    /// @dev About 500,000 gas per wallet, so a full batch is ~10,000,000. Sized for retry cost, since
    ///      a batch that runs out of gas is paid for and lost, and to leave room for
    ///      `forge coverage --ir-minimum`, which adds about a fifth. Refused rather than clamped.
    uint256 public constant MAX_ESIM_WALLETS_PER_CALL = 20;

    /// @dev Retired copy of the upgrade authority, never read (`upgradeManager()` returns `owner()`).
    ///      Kept so nothing below it shifts on the live proxies. Slither's `unused-state` and
    ///      `constable-states` are false here: removing it or making it constant moves every slot.
    address private _retiredUpgradeManager;

    /// @notice Registry contract instance
    Registry public registry;

    /// @notice eSIM identifiers and their details associated with the device identifiers
    mapping(string deviceIdentifier => mapping(string eSIMIdentifier => DataBundleDetails[] dataBundleDetails)) public deviceIdentifierToESIMDetails;

    /// @notice Mapping from eSIM unique identifier to device unique identifier
    /// @dev A device can have many eSIMs, but an eSIM has only one device.
    mapping(string eSIMIdentifier => string deviceIdentifier) public eSIMIdentifierToDeviceIdentifier;

    /// @notice List of eSIM identifiers associated with the device identifiers
    mapping(string deviceIdentifier => string[] associatedESIMIdentifiers) public eSIMIdentifiersAssociatedWithDeviceIdentifier;

    /// @notice How many of an eSIM's stored purchase entries have already reached its wallet
    /// @dev The wallet appends whatever it is handed, so this alone stops a repeat call writing
    ///      entries twice. Read here rather than taken from the caller, so two calls in flight are safe.
    mapping(string eSIMIdentifier => uint256 copied) public historyEntriesCopied;

    /// @notice The eSIM wallet this contract deployed for an eSIM identifier
    /// @dev Without this, a wallet deployed through the ordinary route could claim a lazy user's
    ///      eSIM identifier and receive their history. Written from the deployment's returned
    ///      addresses and not touched by ownership transfers, so the copy follows the wallet.
    mapping(string eSIMIdentifier => address eSIMWallet) public lazyDeployedESIMWallet;

    /// @notice How many of a device's eSIM wallets this contract has already deployed
    /// @dev Non-zero means this contract set the device up, since the first batch deploys at least
    ///      one. Asking the registry instead would also accept a device wallet from the ordinary
    ///      route under the same identifier, and hand it the lazy user's wallets.
    mapping(string deviceIdentifier => uint256 deployed) public eSIMWalletsDeployed;

    /// @notice Salt the device's first deployment batch started from
    /// @dev Later batches continue from this rather than restart on an address already in use.
    ///      Stored, because a caller passing a different salt would silently give different addresses.
    mapping(string deviceIdentifier => uint256 baseSalt) public lazyDeploymentSalt;

    /// @notice Emitted when data related to a device is updated
    event DataUpdatedForDevice(
        string _deviceUniqueIdentifier, string[] _eSIMUniqueIdentifiers, DataBundleDetails[] _dataBundleDetails
    );

    /// @notice Emitted when an eSIM identifier is associated with a device identifier
    event ESIMBindedWithDevice(string _eSIMUniqueIdentifier, string _deviceUniqueIdentifier);

    /// @notice Emitted when the Lazy wallet is deployed
    /// @dev String arrays are left unindexed on purpose: an indexed dynamic type stores only its
    ///      hash, which no consumer can use.
    event LazyWalletDeployed(
        bytes32[2] _deviceOwnerPublicKey,
        address indexed deviceWallet,
        string _deviceUniqueIdentifier,
        address[] eSIMWallets,
        string[] _eSIMUniqueIdentifiers
    );

    /// @notice Emitted for every batch of eSIM wallets deployed for a device, including the first.
    ///         `_remaining` of zero means the device is fully deployed.
    /// @dev `LazyWalletDeployed` carries only the first batch, so follow this for the whole set.
    event LazyESIMWalletsDeployed(
        string _deviceUniqueIdentifier,
        address indexed _deviceWallet,
        address[] _eSIMWallets,
        string[] _eSIMUniqueIdentifiers,
        uint256 _remaining
    );

    /// @notice Emitted for every batch of purchase history copied into a deployed eSIM wallet.
    ///         `_remaining` of zero means the copy is finished.
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
    /// @dev Read from the registry each call, so a rotation there takes effect at once.
    modifier onlyESIMWalletAdmin() {
        if(msg.sender != registry.eSIMWalletAdmin()) revert Errors.OnlyESIMWalletAdmin();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @notice Disables initializers on the implementation contract
    /// @dev Otherwise anyone could initialise and own the implementation, a trap for any later
    ///      upgrade that adds an outward call.
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

    /// @notice Records devices, their eSIMs and the data bundles bought for them
    /// @dev Refused for a device that already has a wallet, which freezes its eSIM list and history
    ///      while a deployment walks them.
    /// @param _deviceUniqueIdentifiers Devices being recorded
    /// @param _eSIMUniqueIdentifiers Per device, the eSIM each purchase was made for
    /// @param _dataBundleDetails Per device, the purchases, aligned with the eSIM identifiers
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
    /// @dev The rest go through `deployMoreESIMWalletsForLazyDevice`: one transaction for every
    ///      wallet stopped fitting in a block past about forty. The device wallet is usable at once,
    ///      so a dropped later batch does not leave the user with nothing. Switching an eSIM is
    ///      refused meanwhile, since the switch refuses any device that has a wallet.
    ///      Pause-checked because it moves ETH. Its two siblings move none and run through a pause
    ///      on purpose, so a half deployed device can still be finished.
    /// @param _deviceOwnerPublicKey P256 public key of the device owner
    /// @param _deviceUniqueIdentifier Device being deployed
    /// @param _salt Salt every eSIM wallet address of the device derives from
    /// @param _depositAmount ETH to deposit in the device wallet
    /// @param _maxWallets Most eSIM wallets to deploy here, at most MAX_ESIM_WALLETS_PER_CALL
    /// @return deviceWallet The deployed device wallet
    /// @return eSIMWallets eSIM wallets deployed here, in the device's identifier order
    /// @return remaining eSIM wallets still waiting
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
        registry.requireNotPaused();
        if(_depositAmount != msg.value) revert Errors.DepositDoesNotMatchValue(_depositAmount, msg.value);
        if(registry.isDeviceIdentifierAlreadyUsed(_deviceUniqueIdentifier)) {
            revert Errors.LazyWalletAlreadyDeployed(_deviceUniqueIdentifier);
        }

        string[] storage allESIMIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
        uint256 total = allESIMIdentifiers.length;
        if(total == 0) revert Errors.NoESIMIdentifiersForDevice(_deviceUniqueIdentifier);

        // Checks the whole salt range now, since later batches continue from it. Overflowing partway
        // would leave a device that can neither be finished nor redeployed.
        if(total + _salt >= type(uint256).max) revert Errors.SaltTooHigh(_salt, total);

        uint256 batchSize = _boundedBatchSize(_maxWallets, total);
        string[] memory batchIdentifiers = _readIdentifiers(allESIMIdentifiers, 0, batchSize);

        // Cursors move before the external call. Every callee is a protocol contract today, but eSIM
        // wallets share one beacon and a later implementation could call back in during setup.
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
    /// @dev Call until it reverts `AllESIMWalletsDeployed`, which means done, not failed.
    ///      No pause check: it moves no ETH, and `_populateHistory` refuses a device with a wallet,
    ///      so the list it walks cannot grow under a running deployment.
    /// @param _deviceUniqueIdentifier Device whose remaining eSIM wallets are being deployed
    /// @param _maxWallets Most eSIM wallets to deploy here, at most MAX_ESIM_WALLETS_PER_CALL
    /// @return eSIMWallets eSIM wallets deployed here, in the device's identifier order
    /// @return remaining eSIM wallets still waiting
    function deployMoreESIMWalletsForLazyDevice(
        string calldata _deviceUniqueIdentifier,
        uint256 _maxWallets
    ) external onlyESIMWalletAdmin returns (address[] memory eSIMWallets, uint256 remaining) {
        uint256 alreadyDeployed = eSIMWalletsDeployed[_deviceUniqueIdentifier];
        // Not the registry's device wallet lookup: that would also accept an ordinary-route wallet
        // under this identifier and give it a lazy user's eSIM wallets and history.
        if(alreadyDeployed == 0) revert Errors.LazyWalletNotDeployed(_deviceUniqueIdentifier);

        string[] storage allESIMIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
        uint256 outstanding = allESIMIdentifiers.length - alreadyDeployed;
        if(outstanding == 0) revert Errors.AllESIMWalletsDeployed(_deviceUniqueIdentifier);

        uint256 batchSize = _boundedBatchSize(_maxWallets, outstanding);
        string[] memory batchIdentifiers = _readIdentifiers(allESIMIdentifiers, alreadyDeployed, batchSize);

        address deviceWallet = registry.uniqueIdentifierToDeviceWallet(_deviceUniqueIdentifier);

        // Moved before the deployment, so a reentrant call finds the cursor past this batch rather
        // than deploying the same positions twice.
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
    /// @dev Kept out of the deployment so neither grows with the other. Call until it reverts
    ///      `HistoryAlreadyCopied`, which means done, not failed. No pause check: it moves no ETH,
    ///      and `_populateHistory` froze these entries once the device had a wallet.
    /// @param _eSIMIdentifier eSIM whose history is being copied
    /// @param _maxEntries Most entries to copy here, at most MAX_HISTORY_ENTRIES_PER_CALL
    /// @return copied Entries written by this call
    /// @return remaining Entries still waiting
    function setHistoryForLazyWallet(
        string calldata _eSIMIdentifier,
        uint256 _maxEntries
    ) external onlyESIMWalletAdmin returns (uint256 copied, uint256 remaining) {
        if(_maxEntries == 0 || _maxEntries > MAX_HISTORY_ENTRIES_PER_CALL) {
            revert Errors.TooManyHistoryEntries(_maxEntries, MAX_HISTORY_ENTRIES_PER_CALL);
        }

        // The only authorisation: set only for wallets this contract deployed, so history cannot
        // be aimed at a wallet someone else made under the same identifier.
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

    /// @notice Moves a fiat user's eSIM to a new device, before either device has a wallet
    /// @dev After deployment the eSIM moves through ESIMWallet's ownership transfer instead.
    /// @param _eSIMIdentifier eSIM being switched
    /// @param _oldDeviceIdentifier Device the eSIM is bound to now
    /// @param _newDeviceIdentifier Device it moves to
    /// @return True if the switch succeeded
    function switchESIMIdentifierToNewDeviceIdentifier(
        string calldata _eSIMIdentifier,
        string calldata _oldDeviceIdentifier,
        string calldata _newDeviceIdentifier
    ) external onlyESIMWalletAdmin returns (bool) {
        if(bytes(_eSIMIdentifier).length == 0) revert Errors.EmptyESIMIdentifier();
        if(bytes(_newDeviceIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();
        // Only the new device is bounded. Bounding the eSIM too would block moving an over-length
        // one off a device recorded before the limit existed.
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
        // A deployed old device would keep owning the eSIM wallet while its history is deleted here.
        // A new device that already has a wallet cannot be lazily deployed, so the eSIM would be orphaned.
        // The first batch creates the device wallet, so this also blocks switches mid-deployment.
        if(registry.isDeviceIdentifierAlreadyUsed(_oldDeviceIdentifier)) {
            revert Errors.LazyWalletAlreadyDeployed(_oldDeviceIdentifier);
        }
        if(registry.isDeviceIdentifierAlreadyUsed(_newDeviceIdentifier)) {
            revert Errors.LazyWalletAlreadyDeployed(_newDeviceIdentifier);
        }

        eSIMIdentifierToDeviceIdentifier[_eSIMIdentifier] = _newDeviceIdentifier;
        emit NewDeviceIdentifierAssociatedWithESIMIdentifier(_eSIMIdentifier, currentDeviceIdentifier, _newDeviceIdentifier);

        _moveESIMPurchaseHistory(_eSIMIdentifier, _oldDeviceIdentifier, _newDeviceIdentifier);
        _moveESIMIdentifierBetweenDeviceLists(_eSIMIdentifier, _oldDeviceIdentifier, _newDeviceIdentifier);

        emit ESIMIdentifierSwitchedToNewDeviceIdentifier(_eSIMIdentifier, _oldDeviceIdentifier, _newDeviceIdentifier);

        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Ownership and upgrades
    // ---------------------------------------------------------------------------------------------

    /// @notice Ownership of this contract is never renounced
    /// @dev Only the owner can upgrade, so renouncing would freeze this logic for good.
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
        if(registry.isDeviceIdentifierAlreadyUsed(_deviceUniqueIdentifier)) {
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

                // An eSIM already held onchain cannot get a second wallet, so lazy purchases under
                // it would be unreachable. Existing bindings skip this: the registry guards them.
                address holder = registry.eSIMWalletForIdentifier(eSIMUniqueIdentifier);
                if(holder != address(0)) {
                    revert Errors.ESIMIdentifierAlreadyClaimed(eSIMUniqueIdentifier, holder);
                }

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

            // These purchases happened before the wallet existed, so no contract here saw the
            // money move. The admin must not be able to claim otherwise.
            if(_dataBundleDetails[i].settlement == Settlement.DeviceWallet) {
                revert Errors.SettlementNotAsserted();
            }

            deviceIdentifierToESIMDetails[_deviceUniqueIdentifier][eSIMUniqueIdentifier].push(_dataBundleDetails[i]);
        }

        emit DataUpdatedForDevice(_deviceUniqueIdentifier, _eSIMUniqueIdentifiers, _dataBundleDetails);
    }

    /// @notice Moves what an eSIM bought to the device taking it over
    /// @dev A switch also needs `_moveESIMIdentifierBetweenDeviceLists` for the list membership.
    /// @param _eSIMIdentifier eSIM being switched
    /// @param _oldDeviceIdentifier Device it is leaving
    /// @param _newDeviceIdentifier Device it is joining
    function _moveESIMPurchaseHistory(
        string calldata _eSIMIdentifier,
        string calldata _oldDeviceIdentifier,
        string calldata _newDeviceIdentifier
    ) internal {
        DataBundleDetails[] storage dataBundleDetails = deviceIdentifierToESIMDetails[_oldDeviceIdentifier][_eSIMIdentifier];
        DataBundleDetails[] storage newDataBundleDetails = deviceIdentifierToESIMDetails[_newDeviceIdentifier][_eSIMIdentifier];
        // Distinct arrays, since the caller refuses a same-device switch, so the bound is read once.
        uint256 entries = dataBundleDetails.length;
        for(uint256 i=0; i<entries; ++i) {
            newDataBundleDetails.push(dataBundleDetails[i]);
        }
        emit DataBundleDetailsTransferredToNewDeviceIdentifier(_newDeviceIdentifier, newDataBundleDetails);

        delete deviceIdentifierToESIMDetails[_oldDeviceIdentifier][_eSIMIdentifier];
        emit DataBundleDetailsDeletedFromOldDeviceIdentifier(_oldDeviceIdentifier, _eSIMIdentifier);
    }

    /// @notice Moves an eSIM identifier between the two devices' lists
    /// @dev This list is what a deployment walks. Removal is swap-and-pop, so the old device's list
    ///      loses its order.
    /// @param _eSIMIdentifier eSIM being switched
    /// @param _oldDeviceIdentifier Device it is leaving
    /// @param _newDeviceIdentifier Device it is joining
    function _moveESIMIdentifierBetweenDeviceLists(
        string calldata _eSIMIdentifier,
        string calldata _oldDeviceIdentifier,
        string calldata _newDeviceIdentifier
    ) internal {
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

        eSIMIdentifierOfOldDevice[i] = eSIMIdentifierOfOldDevice[eSIMIdentifierOfOldDevice.length - 1];
        eSIMIdentifierOfOldDevice.pop();
        emit ESIMIdentifierRemovedFromOldDeviceIdentifier(_oldDeviceIdentifier, _eSIMIdentifier, eSIMIdentifierOfOldDevice);

        string[] storage eSIMIdentifierOfNewDevice = eSIMIdentifiersAssociatedWithDeviceIdentifier[_newDeviceIdentifier];
        eSIMIdentifierOfNewDevice.push(_eSIMIdentifier);
        emit ESIMIdentifierAddedToNewDeviceIdentifier(_newDeviceIdentifier, _eSIMIdentifier, eSIMIdentifierOfNewDevice);
    }

    // ---------------------------------------------------------------------------------------------
    // Batch bounds and records
    // ---------------------------------------------------------------------------------------------

    /// @notice Rejects a batch size outside the cap, then clamps it to what is actually left
    /// @dev Above the cap is refused, so a caller never believes it deployed more than it did.
    ///      Above what is left is clamped, and the return value says how many it got.
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
    /// @dev Reads only the slice, so each call's cost stays bounded by the batch.
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
    /// @dev Relies on the deployment returning wallets in identifier order. The only later proof a
    ///      wallet was deployed here. Runs after the deployment, since the addresses come from it.
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
    /// @dev Reads the owner, who alone can upgrade, rather than a copy that could disagree.
    /// @return The address that may upgrade this contract
    function upgradeManager() public view returns (address) {
        return owner();
    }

    /// @notice How many history entries are still waiting to be copied into this eSIM's wallet
    /// @dev The public getter on `deviceIdentifierToESIMDetails` cannot return a length.
    ///      Zero for an eSIM this contract never handled.
    /// @param _eSIMIdentifier eSIM being asked about
    /// @return Entries still waiting to be copied
    function outstandingHistoryEntries(string calldata _eSIMIdentifier) external view returns (uint256) {
        string memory deviceIdentifier = eSIMIdentifierToDeviceIdentifier[_eSIMIdentifier];
        if(bytes(deviceIdentifier).length == 0) return 0;

        return deviceIdentifierToESIMDetails[deviceIdentifier][_eSIMIdentifier].length
            - historyEntriesCopied[_eSIMIdentifier];
    }

    /// @notice Whether a device identifier has purchases recorded against it here
    /// @dev Checked by the ordinary route, since a wallet under a reserved identifier strands its
    ///      eSIMs. Stays true after lazy deployment, harmless as the registry refuses a second claim.
    /// @param _deviceUniqueIdentifier Device identifier being checked
    /// @return True if a lazy user is waiting on this identifier
    function isDeviceIdentifierReserved(string calldata _deviceUniqueIdentifier) public view returns (bool) {
        return eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier].length != 0;
    }

    /// @notice Whether an eSIM identifier is bound to a device here
    /// @param _eSIMUniqueIdentifier eSIM identifier being checked
    /// @return True if a lazy user is waiting on this identifier
    function isESIMIdentifierReserved(string calldata _eSIMUniqueIdentifier) public view returns (bool) {
        return bytes(eSIMIdentifierToDeviceIdentifier[_eSIMUniqueIdentifier]).length != 0;
    }
}
