// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";
import {SimpleAMM} from "./SimpleAMM.sol";

/// @notice FIXED lending market. Uses a time-weighted average price (TWAP) over at least TWAP_WINDOW.
///
/// Why this works: a price only counts for the number of seconds it was in place. A trade that
/// moves the price and then gets reversed in the same block contributes zero seconds, so it does
/// not move the TWAP at all. An attacker has to hold the manipulated price for a full window, which
/// means locking capital and taking arbitrage risk for that time.
contract SecureLending {
    MockERC20 public immutable collateralToken;
    MockERC20 public immutable borrowToken;
    SimpleAMM public immutable oracle;

    uint256 public constant COLLATERAL_FACTOR = 75; // percent
    uint256 public constant TWAP_WINDOW = 30 minutes;

    struct Checkpoint {
        uint256 cumulative;
        uint256 timestamp;
    }

    // The TWAP is measured between prevCheckpoint and now. lastCheckpoint is the next candidate.
    Checkpoint public prevCheckpoint;
    Checkpoint public lastCheckpoint;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    constructor(address _collateralToken, address _borrowToken, address _oracle) {
        collateralToken = MockERC20(_collateralToken);
        borrowToken = MockERC20(_borrowToken);
        oracle = SimpleAMM(_oracle);

        uint256 c = oracle.currentCumulative();
        prevCheckpoint = Checkpoint(c, block.timestamp);
        lastCheckpoint = Checkpoint(c, block.timestamp);
    }

    /// @notice Anyone can roll checkpoints forward once a full window has passed.
    function checkpoint() external {
        if (block.timestamp - lastCheckpoint.timestamp >= TWAP_WINDOW) {
            prevCheckpoint = lastCheckpoint;
            lastCheckpoint = Checkpoint(oracle.currentCumulative(), block.timestamp);
        }
    }

    /// @notice Time-weighted average token1-per-token0 price over [prevCheckpoint.timestamp, now].
    function twapPrice() public view returns (uint256) {
        uint256 elapsed = block.timestamp - prevCheckpoint.timestamp;
        require(elapsed >= TWAP_WINDOW, "twap window too short");
        return (oracle.currentCumulative() - prevCheckpoint.cumulative) / elapsed;
    }

    function supply(uint256 amount) external {
        borrowToken.transferFrom(msg.sender, address(this), amount);
    }

    function depositCollateral(uint256 amount) external {
        collateralToken.transferFrom(msg.sender, address(this), amount);
        collateral[msg.sender] += amount;
    }

    function borrow(uint256 amount) external {
        // FIXED: value collateral at the time-weighted price, not the spot price.
        uint256 price = twapPrice();

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
