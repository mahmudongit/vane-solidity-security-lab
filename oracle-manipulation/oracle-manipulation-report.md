# Security Audit Report: Oracle Manipulation via Spot Price in a Lending Market

**Auditor:** Vane (@vanebuilds_)
**Scope:** `InsecureLending.sol` (vulnerable), `OracleAttacker.sol` (attacker), `SecureLending.sol` (fix)
**Classification:** Oracle Manipulation / Price Feed Dependence
**Status:** ✅ Verified: `forge test` passes 5/5 tests. Mitigated by TWAP.

---

## 1. Executive Summary

`InsecureLending` values collateral using the **spot price of a constant-product AMM read inside the same transaction**. Anyone with enough capital can move that spot price for the length of one transaction using a flash loan, borrow against the inflated collateral value, then restore the price and repay the flash loan. The borrowed funds stay with the attacker and become bad debt for the lender.

The fix replaces the spot read with a **time-weighted average price (TWAP)**. A price only counts for the number of seconds it stays in place, so a same-block manipulation has zero weight and the attack fails.

| Metric | Value |
|---|---|
| Vulnerability | Oracle manipulation (spot price used as collateral oracle) |
| Severity | Critical |
| Attack cost | Flash loan fee (zero in the lab) + AMM fees (about 0.6% of the flash amount) |
| Attacker profit (lab numbers) | about 99.5k token1 |
| Bad debt created (lab numbers) | about 90k token1 |
| Preconditions | Lending market prices collateral from an AMM spot price; flash-loan liquidity exists; AMM is shallow relative to the flash loan |

---

## 2. Vulnerability Overview

### What is an oracle?

A lending protocol needs to know what collateral is worth. The "oracle" is the source for that price. Using the current spot price of an AMM pool is attractive because it is on-chain and easy to read, but the spot price is a function of the pool's reserves, and reserves change with every trade.

### Why spot prices are unsafe

- The price is set by reserves, and reserves can be changed by any trader.
- A flash loan gives an attacker large capital at no upfront cost, as long as the loan is repaid in the same transaction.
- Inside one transaction the attacker can trade (moving the price), act on the moved price (borrowing), and trade back (restoring the price). Nothing outside the transaction ever observes the moved price.

---

## 3. Vulnerable Contract: InsecureLending

**File:** `src/InsecureLending.sol`

```solidity
function borrow(uint256 amount) external {
    // VULNERABLE: reads the spot price inside the same transaction that may have just moved it.
    uint256 price = oracle.spotPrice();

    uint256 collateralValue = (collateral[msg.sender] * price) / 1e18;
    uint256 newDebt = debt[msg.sender] + amount;
    require(newDebt * 100 <= collateralValue * COLLATERAL_FACTOR, "undercollateralized");

    debt[msg.sender] = newDebt;
    borrowToken.transfer(msg.sender, amount);
}
```

**Root cause:** `oracle.spotPrice()` is `reserve1 * 1e18 / reserve0`. Anything that changes the reserves in the same transaction changes the collateral value used by `borrow()`.

---

## 4. Attack Contract: OracleAttacker

**File:** `src/OracleAttacker.sol`

The attack runs inside one flash-loan callback:

| Step | Action | Effect on AMM price |
|---|---|---|
| 1. Pump | Flash-borrow 300,000 token1, swap it for token0 | token0 gets scarcer, price rises from 1000 to about 15,964 |
| 2. Borrow | `lending.borrow(100,000)` against 10 token0 of collateral | Collateral value is now about 119k, so the borrow passes |
| 3. Dump | Sell the token0 back into the AMM | Price returns to about 1000 (0.45% higher from fees kept in the pool) |
| 4. Repay | Return 300,000 token1 to the flash lender | Attacker keeps the 100,000 token1 borrowed in step 2 |

The attacker needs a small token1 buffer (10,000 in the tests) to cover the round-trip fee, because the dump returns slightly less than the flash amount.

---

## 5. Proof of Concept

**File:** `test/OracleManipulation.t.sol`

### 5.1 Exploit against the vulnerable market

```solidity
insecureAttacker.attack(300_000e18, 100_000e18);

assertEq(insecure.debt(address(insecureAttacker)), 100_000e18);
assertApproxEqRel(amm.spotPrice(), FAIR_PRICE, 0.01e18); // price restored
assertGt(profit, 90_000e18);                              // attacker profit
assertGt(debt - fairCollateralValue, 80_000e18);          // bad debt for suppliers
```

Expected result: the borrow succeeds, the attacker holds 100k of debt against collateral worth 10k at fair price, and the lender has about 90k of bad debt.

### 5.2 Same attack against the fixed market

```solidity
vm.warp(block.timestamp + secure.TWAP_WINDOW());
vm.expectRevert("undercollateralized");
secureAttacker.attack(300_000e18, 100_000e18);
```

Expected result: the TWAP is still about 1000 because the pumped price has zero seconds of weight, so the maximum borrow is 7,500 and the attack reverts.

### 5.3 Same-block manipulation does not move the TWAP

A whale moves the spot price to about 15,964 within the same block. The test asserts the spot price is pumped but `twapPrice()` is exactly unchanged.

### 5.4 Honest borrowing still works

10 token0 of collateral supports a 7,000 borrow at a 75% factor. A 7,600 borrow reverts.

### 5.5 Limitation: sustained manipulation

If an attacker holds the pumped price for a full TWAP window with 300,000 of their own capital, the TWAP moves to about 15,956 and a 100,000 borrow succeeds. The test (`test_Secure_SustainedManipulation_StillMovesTwap`) documents this. It is a cost, not a bypass: the attacker must lock capital, take arbitrage risk for 30 minutes, and be willing to hold the position.

---

## 6. Impact Assessment

| Factor | Rating | Notes |
|---|---|---|
| Severity | Critical | Direct loss of lender funds equal to borrowed amount minus collateral value |
| Likelihood | High for shallow pools | Flash loans are cheap; many lending markets use spot prices from thin pools |
| Attack cost | Near zero | Flash loan fee plus AMM fees on the round trip |
| Affected users | All suppliers | Bad debt reduces what suppliers can withdraw |

### Real-World Parallels

Oracle manipulation with flash loans has caused large losses in production DeFi. Verify the figures before publishing:
- **Cream Finance (2021):** flash-loan-driven price manipulation of a collateral asset, reported loss in the order of $100M+.
- **Mango Markets (2022):** a trader pushed the price of the perpetual market's own collateral token, then borrowed against it.
- **Harvest Finance (2020):** Curve pool price moved with flash loans to exploit vault share pricing.

---

## 7. Mitigation Analysis

### 7.1 Fix: TWAP oracle

**File:** `src/SecureLending.sol`

The AMM keeps a running sum of `price × seconds` (`priceCumulative`). The lending market stores checkpoints of that sum and computes the average price over a window of at least `TWAP_WINDOW` (30 minutes):

```solidity
function twapPrice() public view returns (uint256) {
    uint256 elapsed = block.timestamp - prevCheckpoint.timestamp;
    require(elapsed >= TWAP_WINDOW, "twap window too short");
    return (oracle.currentCumulative() - prevCheckpoint.cumulative) / elapsed;
}
```

**Why it works:** a trade's price is accumulated only for the seconds until the next trade. A manipulation that is reversed in the same block adds `price × 0 = 0` to the sum.

### 7.2 Limits of the fix

A TWAP is not a complete oracle. Consider these before using it in production:

1. **Window length.** A 30-minute window raises the cost of manipulation but does not eliminate it, as section 5.5 shows. The right window depends on how liquid the pool is and how much capital an attacker could bring.
2. **Pool depth.** A deep, well-arbitraged pool is much harder to move for a sustained period. A TWAP on a thin pool is still cheap to manipulate.
3. **Stale prices.** The fixed contract can only be used after a checkpoint has aged. Real protocols must handle a stalled or abandoned oracle explicitly.
4. **Second source.** Production markets typically cross-check the TWAP against an independent feed such as Chainlink, and pause borrowing on large deviation.
5. **Liquidation.** This module does not include liquidation. A production fix must apply the same oracle to liquidation, or positions can become unliquidatable.

---

## 8. Test Results

| Test | Market | Expected result |
|---|---|---|
| `test_Insecure_SpotManipulation_DrainsLender` | Vulnerable | Attack succeeds, profit about 99.5k, bad debt about 90k |
| `test_Secure_SameAttack_Reverts` | Fixed | Attack reverts with `undercollateralized` |
| `test_Secure_SameBlockManipulation_DoesNotMoveTwap` | Fixed | Spot pumped, TWAP unchanged |
| `test_Secure_HonestBorrow_Works` | Fixed | 7,000 borrow passes, 7,600 reverts |
| `test_Secure_SustainedManipulation_StillMovesTwap` | Fixed | Documented limitation: a sustained, capital-backed pump still borrows |

All five tests pass under `forge test --match-contract OracleManipulationTest -vvvv`. The traces confirm the figures: the pumped spot price is about 15,964, the attacker's balance rises from 10,000 to 109,549 token1 (profit about 99.5k), the spot price after the dump is about 1,004.5, and the TWAP stays at exactly 1,000 in the same-block test.

---

## 9. Recommendations

1. Never price collateral from a spot price in the same transaction that can move it.
2. Use a TWAP over a window long enough for the pool's depth, and cross-check with an independent source.
3. Apply the oracle consistently: borrowing, withdrawal and liquidation all need the same price.
4. Cap borrowing against any single pool, and monitor for large price deviations.
5. Test with flash-loan attackers, not only honest users. The fix is only proven by the attack failing.

---

## 10. References

- Uniswap v2 oracle documentation (TWAP accounting and `priceCumulative`): docs.uniswap.org
- Consensys Smart Contract Best Practices, oracle and price manipulation sections
- Chainlink documentation on price feed deviation and heartbeat

---

*Report prepared by Vane. Educational lab module. Do not deploy the vulnerable contracts with real funds.*
