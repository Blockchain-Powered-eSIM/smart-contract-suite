# Solidity API

## UpgradeableBeacon

_Beacon contract holds information about the implementation contract
     and is used by all the proxy contracts to interact with the implementation contract
     A beacon proxy is used in scenarios where a single implementation contract is used by
     multiple proxy contracts. In this case, eSIM wallets and device wallets_

### Upgraded

```solidity
event Upgraded(address implementationContractAddress)
```

Emitted when the implementation returned by the beacon is updated.

### constructor

```solidity
constructor(address _implementation, address _owner) public
```

_ownership is transferred to an address owned by admin_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _implementation | address | Address of the logic (implementation) contract |
| _owner | address |  |

### implementation

```solidity
function implementation() external view returns (address)
```

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | current implementation contract address |

### updateImplementation

```solidity
function updateImplementation(address _newImplementationContractAddress) external
```

Allows the admin to update the logic (implementation) contract address

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newImplementationContractAddress | address | Address of the new implementation contract |

