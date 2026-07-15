// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract SecureAuction {
    struct Commit {
        bytes32 commitHash;
        uint256 blockNumber;
    }

    mapping(address => Commit) public commits;
    mapping(address => uint256) public revealedBids;

    address public highestBidder;
    uint256 public highestBid;
    uint256 public prize = 10 ether;
    bool public revealPhase;

    function commit(bytes32 _commitHash) external {
        require(!revealPhase, "Commit phase over");
        commits[msg.sender] = Commit(_commitHash, block.number);
    }

    function startReveal() external {
        revealPhase = true;
    }

    function reveal(uint256 _bid, uint256 _nonce) external {
        require(revealPhase, "Not reveal phase");
        require(block.number > commits[msg.sender].blockNumber, "Wait one block");

        bytes32 expected = keccak256(abi.encodePacked(_bid, _nonce, msg.sender));
        require(commits[msg.sender].commitHash == expected, "Invalid reveal");

        revealedBids[msg.sender] = _bid;
        if (_bid > highestBid) {
            highestBid = _bid;
            highestBidder = msg.sender;
        }
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