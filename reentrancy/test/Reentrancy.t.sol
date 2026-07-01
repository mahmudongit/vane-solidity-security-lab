// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SimpleBankFixCEI.sol";
import "../src/SimpleBankFixReentrancyGuard.sol";

// CEI attacker: uses try/catch so reentry failure doesnt bubble up
contract AttackerCEI {
    SimpleBankFixCEI public bank;
    uint256 public count;

    constructor(address _bank) { bank = SimpleBankFixCEI(_bank); }

    receive() external payable {
        if (count < 3) {
            count++;
            try bank.withdraw() {} catch {}
        }
    }

    function attack() external payable {
        bank.deposit{value: msg.value}();
        bank.withdraw();
    }
}

// Guard attacker: same try/catch approach
contract AttackerGuard {
    SimpleBankFixReentrancyGuard public bank;
    uint256 public count;

    constructor(address _bank) { bank = SimpleBankFixReentrancyGuard(_bank); }

    receive() external payable {
        if (count < 3) {
            count++;
            try bank.withdraw() {} catch {}
        }
    }

    function attack() external payable {
        bank.deposit{value: msg.value}();
        bank.withdraw();
    }
}

contract ReentrancyTest is Test {
    SimpleBankFixCEI public ceiBank;
    SimpleBankFixReentrancyGuard public guardBank;
    AttackerCEI public attackerCEI;
    AttackerGuard public attackerGuard;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        ceiBank   = new SimpleBankFixCEI();
        guardBank = new SimpleBankFixReentrancyGuard();
        attackerCEI   = new AttackerCEI(address(ceiBank));
        attackerGuard = new AttackerGuard(address(guardBank));

        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(address(attackerCEI),   10 ether);
        vm.deal(address(attackerGuard), 10 ether);
    }

    // CEI: attacker gets their 1 ETH back, but cannot steal others funds
    function test_CEIPreventsReentrancy() public {
        vm.prank(alice); ceiBank.deposit{value: 1 ether}();
        vm.prank(bob);   ceiBank.deposit{value: 1 ether}();

        uint256 bankBefore = ceiBank.getBankBalance(); // 2 ETH
        uint256 attackerBefore = address(attackerCEI).balance;

        vm.prank(address(attackerCEI));
        attackerCEI.attack{value: 1 ether}();

        // Attacker recovered their own 1 ETH and did not profit
        assertEq(address(attackerCEI).balance, attackerBefore);
        // Alice and Bob funds untouched
        assertEq(ceiBank.getBankBalance(), bankBefore);
        // Reentry was attempted but blocked (balance was already 0)
        assertEq(attackerCEI.count(), 1);
    }

    // Guard: attacker gets their 1 ETH back, reentry blocked by mutex
    function test_GuardPreventsReentrancy() public {
        vm.prank(alice); guardBank.deposit{value: 1 ether}();
        vm.prank(bob);   guardBank.deposit{value: 1 ether}();

        uint256 bankBefore = guardBank.getBankBalance(); // 2 ETH
        uint256 attackerBefore = address(attackerGuard).balance;

        vm.prank(address(attackerGuard));
        attackerGuard.attack{value: 1 ether}();

        // Attacker recovered their own 1 ETH and did not profit
        assertEq(address(attackerGuard).balance, attackerBefore);
        // Alice and Bob funds untouched
        assertEq(guardBank.getBankBalance(), bankBefore);
        // Reentry was attempted but blocked by nonReentrant
        assertEq(attackerGuard.count(), 1);
    }
}