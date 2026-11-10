// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

interface IFlashBorrower {
    function onFlashLoan(uint256 amount, bytes calldata data) external;
}

/// @notice Zero-fee flash loan for the lab. Real flash loans (Aave, Balancer, Uniswap flash swaps)
/// work the same way: the whole loan must be repaid before the transaction ends.
contract MockFlashLender {
    MockERC20 public immutable token;

    constructor(address _token) {
        token = MockERC20(_token);
    }

    function flashLoan(address receiver, uint256 amount, bytes calldata data) external {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transfer(receiver, amount);
        IFlashBorrower(receiver).onFlashLoan(amount, data);
        require(token.balanceOf(address(this)) >= balanceBefore, "flash loan not repaid");
    }
}
