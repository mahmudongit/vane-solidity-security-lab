# Security Audit Report: Reentrancy Vulnerability in SimpleBank

**Auditor:** Mahmud (@vanebuilds_)  
**Date:** June 2026  
**Scope:** `SimpleBank.sol` — Deposit & Withdraw functionality  
**Classification:** Smart Contract Logic Vulnerability  
**Status:** ✅ Mitigated & Verified

---

## 1. Executive Summary

A **critical reentrancy vulnerability** was identified in the `SimpleBank.withdraw()` function. The contract performs an external ETH transfer **before** updating the caller's internal balance mapping. This allows a malicious contract to recursively re-enter `withdraw()` and drain the bank's entire ETH balance.

Two independent mitigations were implemented and verified via Foundry:
- **Checks-Effects-Interactions (CEI)** pattern
- **OpenZeppelin ReentrancyGuard** (`nonReentrant` modifier)

Both mitigations successfully prevent fund drainage while preserving core functionality.

---

## 2. Vulnerability Details

### 2.1 Affected Contract
- **File:** `src/SimpleBank.sol`
- **Contract:** `SimpleBank`
- **Function:** `withdraw()`

### 2.2 Vulnerable Code

```solidity
// SimpleBank.sol
function withdraw() external {
    uint256 bal = balances[msg.sender];
    require(bal >= 1 ether, "Insufficient balance");

    // ❌ EXTERNAL CALL BEFORE STATE UPDATE (VULNERABLE)
    (bool success, ) = msg.sender.call{value: bal}("");
    require(success, "Transfer failed");

    // State update happens too late
    balances[msg.sender] = 0;
}
```

### 2.3 Root Cause

The vulnerability follows the classic **SWC-136 (Reentrancy)** pattern:

1. **Check:** `require(bal >= 1 ether)` — validates the user has a balance.
2. **Interaction:** `msg.sender.call{value: bal}("")` — sends ETH to the caller. If the caller is a smart contract, its `receive()` or `fallback()` function is executed.
3. **Effect:** `balances[msg.sender] = 0` — updates the internal ledger.

Because step 2 occurs before step 3, the attacker's balance remains non-zero during the external call. The attacker’s `receive()` function can recursively call `withdraw()`, which again reads the stale balance and sends more ETH.

---

## 3. Proof of Concept

### 3.1 Attack Contract

The attacker contract (`Attacker` in `test/BlackHat.t.sol`) implements a `receive()` function that re-enters `SimpleBank.withdraw()` up to 3 additional times:

```solidity
receive() external payable {
    if (count < 3) {
        count++;
        bank.withdraw();  // Re-enter before original call completes
    }
}
```

### 3.2 Foundry Test: Exploit Verification

**Test:** `test_ReentrancyAttack_DrainsBank()` in `test/BlackHat.t.sol`

**Setup:**
- 4 honest users (Alice, Bob, Charlie, Dave) deposit 1 ETH each → **4 ETH in bank**
- Attacker deposits 1 ETH → **5 ETH total in bank**

**Execution:**
```solidity
vm.prank(address(attacker));
attacker.attack{value: 1 ether}();
```

**Result:**
| Metric | Value |
|--------|-------|
| Attacker profit | **+3 ETH** (4 ETH withdrawn minus 1 ETH deposit) |
| Bank remaining balance | **1 ETH** (only the attacker's original deposit remains) |
| Honest user funds | **Stolen** — Alice, Bob, Charlie, and Dave cannot withdraw |

**Assertion (passing):**
```solidity
assertEq(address(attacker).balance, attackerBefore + 3 ether);
assertEq(bank.getBankBalance(), 1 ether);
```

> **Impact:** Complete loss of depositor funds. The bank becomes insolvent.

---

## 4. Impact Assessment

| Factor | Rating | Notes |
|--------|--------|-------|
| **Severity** | 🔴 **Critical** | Direct loss of all ETH held by the contract |
| **Likelihood** | **High** | No access control required; any contract can call `withdraw()` |
| **Attack Cost** | **~1 ETH** | Attacker only needs to deposit the minimum to trigger the exploit |
| **Affected Users** | **All depositors** | Entire contract balance is at risk |

### Real-World Parallels
This exact pattern has caused catastrophic losses in production:
- **The DAO Hack (2016):** ~3.6M ETH stolen via reentrancy
- **Uniswap/Lendf.me (2020):** $25M+ lost to similar callback reentrancy
- **Curve Finance (2023):** Reentrancy in compiler-optimized pools led to multi-million dollar exploits

---

## 5. Mitigation Analysis

Two fixes were implemented and independently verified. Both preserve the 1 ETH minimum deposit requirement and full withdrawal functionality.

### 5.1 Fix A: Checks-Effects-Interactions (CEI)

**File:** `src/SimpleBankFixCEI.sol`

**Change:** Move the state update (`balances[msg.sender] = 0`) **before** the external call.

```solidity
function withdraw() external {
    uint256 bal = balances[msg.sender];
    require(bal >= 1 ether, "Insufficient balance");

    // ✅ EFFECTS FIRST
    balances[msg.sender] = 0;

    // ✅ INTERACTION LAST
    (bool success, ) = msg.sender.call{value: bal}("");
    require(success, "Transfer failed");
}
```

**Mechanism:** When the attacker’s `receive()` re-enters, `balances[msg.sender]` is already `0`. The `require(bal >= 1 ether)` check fails, reverting the recursive call.

**Test Result:** `test_CEIPreventsReentrancy()` passes.
- Attacker recovers their original 1 ETH deposit only.
- Bank balance remains unchanged (2 ETH in test setup).
- `attackerCEI.count()` equals `1`, confirming the reentry was attempted once and blocked.

**Gas Impact:** Minimal. Reordering statements adds **zero additional gas overhead**.

---

### 5.2 Fix B: OpenZeppelin ReentrancyGuard

**File:** `src/SimpleBankFixReentrancyGuard.sol`

**Change:** Inherit from `ReentrancyGuard` and apply the `nonReentrant` modifier to `withdraw()`.

```solidity
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SimpleBankFixReentrancyGuard is ReentrancyGuard {
    // ...
    function withdraw() external nonReentrant {
        uint256 bal = balances[msg.sender];
        require(bal >= 1 ether, "Insufficient balance");

        balances[msg.sender] = 0;
        (bool success, ) = msg.sender.call{value: bal}("");
        require(success, "Transfer failed");
    }
}
```

**Mechanism:** The `nonReentrant` modifier sets a transient storage flag on entry and reverts if the same function is called again before completion. This acts as a **mutex lock** at the function level.

**Test Result:** `test_GuardPreventsReentrancy()` passes.
- Attacker recovers their original 1 ETH deposit only.
- Bank balance remains unchanged.
- `attackerGuard.count()` equals `1`, confirming the reentry was blocked by the modifier.

**Gas Impact:** Adds approximately **~2,500–3,000 gas** per `withdraw()` call due to transient storage slot updates (cheaper in Solidity ≥0.8.20, but still non-zero).

---

### 5.3 Mitigation Comparison

| Criteria | CEI Pattern | ReentrancyGuard |
|----------|-------------|-----------------|
| **Gas Cost** | Free (reordering only) | ~2,500–3,000 gas overhead |
| **Complexity** | Low (no imports) | Low (single modifier) |
| **Coverage** | Protects only this function | Protects any function with `nonReentrant` |
| **Cross-Function Reentrancy** | Vulnerable* | Protected |
| **Best For** | Simple single-function transfers | Complex protocols with multiple entry points |

\* *Note: CEI alone does not protect against cross-function reentrancy (e.g., `withdraw()` re-entering via `deposit()` or another state-changing function). For production multi-function contracts, **CEI + ReentrancyGuard is the gold standard**.*

**Recommendation:** For this single-function bank, **CEI is sufficient and preferred** due to zero gas overhead. For production DeFi protocols with multiple external entry points, **combine both**.

---

## 6. Code Diff

### Before (Vulnerable)
```solidity
function withdraw() external {
    uint256 bal = balances[msg.sender];
    require(bal >= 1 ether, "Insufficient balance");

    (bool success, ) = msg.sender.call{value: bal}("");  // Interaction
    require(success, "Transfer failed");

    balances[msg.sender] = 0;  // Effect (too late)
}
```

### After (CEI Fix)
```solidity
function withdraw() external {
    uint256 bal = balances[msg.sender];
    require(bal >= 1 ether, "Insufficient balance");

    balances[msg.sender] = 0;  // Effect (first)

    (bool success, ) = msg.sender.call{value: bal}("");  // Interaction (last)
    require(success, "Transfer failed");
}
```

---

## 7. Additional Security Notes

1. **Use `transfer` or `send`?** No. While `transfer` and `send` limit gas to 2300 and prevent reentrancy via complex fallback logic, they are **not recommended** post-Istanbul hard fork. Smart contract wallets (Gnosis Safe, Argent) may have `receive()` functions that exceed 2300 gas, causing legitimate withdrawals to revert. `call{value:...}` with CEI/ReentrancyGuard is the modern best practice.

2. **Pull Over Push:** For production systems, consider a **withdrawal pattern** where users explicitly `claim()` funds rather than the contract automatically `push`ing them. This shifts reentrancy risk to user-controlled claim functions.

3. **Unit Testing:** The Foundry test suite demonstrates a robust testing pattern:
   - `setUp()` deploys contracts and funds accounts using `vm.deal()`
   - Exploit tests verify the vulnerability
   - Mitigation tests verify the fix without regression
   - Consider adding a test for **cross-function reentrancy** if the contract grows.

---

## 8. References

- [SWC-136: Unprotected Ether Withdrawal](https://swcregistry.io/docs/SWC-136/)
- [Consensys Smart Contract Best Practices: Reentrancy](https://consensys.github.io/smart-contract-best-practices/attacks/reentrancy/)
- [OpenZeppelin: ReentrancyGuard](https://docs.openzeppelin.com/contracts/5.x/api/utils#ReentrancyGuard)
- [Solidity Docs: Security Considerations — Reentrancy](https://docs.soliditylang.org/en/latest/security-considerations.html#reentrancy)
- [The DAO Hack Post-Mortem (2016)](https://blog.ethereum.org/2016/06/17/critical-update-re-dao-vulnerability)

---

## 9. Conclusion

The `SimpleBank` contract contained a **critical reentrancy vulnerability** that allowed complete drainage of depositor funds. The vulnerability was successfully reproduced via Foundry, then mitigated using two industry-standard approaches:

1. **Checks-Effects-Interactions (CEI)** — zero-cost, logic-level fix
2. **OpenZeppelin ReentrancyGuard** — robust, modifier-based protection

All tests pass. The contract is **secure against single-function reentrancy** in its current form.

> **For production deployment**, it is recommended to:
> - Maintain CEI ordering **and** apply `nonReentrant` to all state-changing external functions
> - Add comprehensive access control (e.g., `Ownable` for emergency pause)
> - Conduct a full protocol audit before managing real user funds

---

*Report prepared by Mahmud — Smart Contract Security Focused Developer*  
*Available for security audits and ERC20/ERC721/ERC1155 development.*  
*X: [@vanebuilds_](https://x.com/vanebuilds_) | GitHub: [mahmudongit](https://github.com/mahmudongit)*
