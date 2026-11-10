# Oracle Manipulation

A lending market prices collateral from an AMM spot price. A flash-loan attacker moves that price inside one transaction, borrows against it, and restores the price.

## Files

| Path | Role |
|---|---|
| `src/InsecureLending.sol` | Vulnerable: spot-price collateral valuation |
| `src/OracleAttacker.sol` | Attacker: pump, borrow, dump, repay |
| `src/SecureLending.sol` | Fixed: time-weighted average price (TWAP) |
| `src/SimpleAMM.sol` | Constant-product AMM used as the price source |
| `src/MockFlashLender.sol` | Zero-fee flash loan |
| `src/MockERC20.sol` | Test token |
| `test/OracleManipulation.t.sol` | Exploit, fix, honest use, and limitation tests |
| `oracle-manipulation-report.md` | Full write-up |

## Running

```bash
forge install foundry-rs/forge-std
forge test -vvv
```

This module has no OpenZeppelin dependency.
