// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SecureAuction.sol";

contract CommitRevealTest is Test {
    SecureAuction public auction;

    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    function setUp() public {
        auction = new SecureAuction();
        vm.deal(alice, 10 ether);
        vm.deal(attacker, 10 ether);
        vm.deal(address(auction), 10 ether);
        auction.fundPrize{value: 10 ether}();
    }

    // Commit-reveal hides the bid value — attacker cannot front-run
    function test_CommitRevealPreventsFrontRunning() public {
        uint256 aliceBid = 1 ether;
        uint256 aliceNonce = 42;
        bytes32 aliceCommit = keccak256(abi.encodePacked(aliceBid, aliceNonce, alice));

        // Alice commits (hash reveals nothing about the actual bid)
        vm.prank(alice);
        auction.commit(aliceCommit);

        // Attacker sees the commit tx but cannot extract the bid from the hash
        // They must commit blindly without knowing Alice's bid
        uint256 attackerBid = 0.5 ether; // attacker guesses too low
        uint256 attackerNonce = 99;
        bytes32 attackerCommit = keccak256(abi.encodePacked(attackerBid, attackerNonce, attacker));

        vm.prank(attacker);
        auction.commit(attackerCommit);

        // Move to reveal phase and advance one block
        auction.startReveal();
        vm.roll(block.number + 1);

        // Both reveal
        vm.prank(alice);
        auction.reveal(aliceBid, aliceNonce);

        vm.prank(attacker);
        auction.reveal(attackerBid, attackerNonce);

        // Alice wins because attacker could not front-run her hidden bid
        assertEq(auction.highestBidder(), alice);
        assertEq(auction.highestBid(), 1 ether);
    }

    // Cannot reveal in the same block as commit (prevents mempool peeking)
    function test_CannotRevealSameBlock() public {
        uint256 bid = 1 ether;
        uint256 nonce = 42;
        bytes32 commitHash = keccak256(abi.encodePacked(bid, nonce, alice));

        vm.prank(alice);
        auction.commit(commitHash);

        auction.startReveal();
        // Do NOT roll forward

        vm.prank(alice);
        vm.expectRevert("Wait one block");
        auction.reveal(bid, nonce);
    }

    // Invalid reveal (wrong nonce) reverts
    function test_InvalidRevealReverts() public {
        uint256 bid = 1 ether;
        uint256 nonce = 42;
        bytes32 commitHash = keccak256(abi.encodePacked(bid, nonce, alice));

        vm.prank(alice);
        auction.commit(commitHash);

        auction.startReveal();
        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert("Invalid reveal");
        auction.reveal(bid, 999); // wrong nonce
    }
}