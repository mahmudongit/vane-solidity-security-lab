// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract InsecureAuction {
    address public highestBidder;
    uint256 public highestBid;
    uint256 public prize = 10 ether;

    function bid() external payable {
        require(msg.value > highestBid, "Bid too low");
        highestBidder = msg.sender;
        highestBid = msg.value;
    }

    function claimPrize() external {
        require(msg.sender == highestBidder, "Not winner");
        require(prize > 0, "Already claimed");
        uint256 payout = prize;
        prize = 0;
        (bool success, ) = msg.sender.call{value: payout}("");
        require(success, "Transfer failed");
    }

    function fundPrize() external payable {
        prize += msg.value;
    }
}