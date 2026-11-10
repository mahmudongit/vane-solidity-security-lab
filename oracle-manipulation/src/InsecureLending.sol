// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";
import {SimpleAMM} from "./SimpleAMM.sol";

/**
 * @title Oracle Manipulation Vulnerability.
 * @author Mahmud
 * @notice VULNERABLE lending market. Collateral is token0, debt is token1. 
 * The collateral price comes straight from the AMM's current spot price.
*/

contract InsecureLending {
    MockERC20 public immutable collateralToken;
    MockERC20 public immutable borrowToken;
    SimpleAMM public immutable oracle;

    uint256 public constant COLLATERAL_FACTOR = 75; // percent

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    constructor(address _collateralToken, address _borrowToken, address _oracle) {
        collateralToken = MockERC20(_collateralToken);
        borrowToken = MockERC20(_borrowToken);
        oracle = SimpleAMM(_oracle);
    }

    function supply(uint256 amount) external {
        borrowToken.transferFrom(msg.sender, address(this), amount);
    }

    function depositCollateral(uint256 amount) external {
        collateralToken.transferFrom(msg.sender, address(this), amount);
        collateral[msg.sender] += amount;
    }

    function borrow(uint256 amount) external {
        // VULNERABLE: reads the spot price inside the same transaction that may have just moved it.
        // Nothing here is time-weighted, and there is no check against a second price source.
        uint256 price = oracle.spotPrice();

        uint256 collateralValue = (collateral[msg.sender] * price) / 1e18;
        uint256 newDebt = debt[msg.sender] + amount;
        require(newDebt * 100 <= collateralValue * COLLATERAL_FACTOR, "undercollateralized");

        debt[msg.sender] = newDebt;
        borrowToken.transfer(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        debt[msg.sender] -= amount;
        borrowToken.transferFrom(msg.sender, address(this), amount);
    }
}
