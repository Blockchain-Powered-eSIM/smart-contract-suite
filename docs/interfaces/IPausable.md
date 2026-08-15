# Solidity API

## IPausable

Minimal view of the pause a guardian is allowed to release

_Only `unpause()` is here. Raising a pause is the hot admin key's lever and releasing one is
     the timelock's, so the two are deliberately not offered through the same interface._

### unpause

```solidity
function unpause() external
```

Clears the pause

