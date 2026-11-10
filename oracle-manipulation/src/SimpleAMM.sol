// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal constant-product AMM (x * y = k) with a 0.3% fee.
///
/// This is the price source the lending protocol uses. Its spot price is set by the
/// current reserves, so anyone with enough capital can move it inside a single transaction.
/// It also keeps a Uniswap-v2-style cumulative price, which the fixed lending contract uses.
contract SimpleAMM {
    MockERC20 public immutable token0; // collateral token
    MockERC20 public immutable token1; // borrow token

    uint256 public reserve0;
    uint256 public reserve1;

    // Running sum of (price * seconds). Price = token1 per token0, scaled by 1e18.
    uint256 public priceCumulative;
    uint256 public lastUpdate;

    constructor(address _token0, address _token1) {
        token0 = MockERC20(_token0);
        token1 = MockERC20(_token1);
        lastUpdate = block.timestamp;
    }

    function addLiquidity(uint256 amount0, uint256 amount1) external {
        _update();
        token0.transferFrom(msg.sender, address(this), amount0);
        token1.transferFrom(msg.sender, address(this), amount1);
        reserve0 += amount0;
        reserve1 += amount1;
    }

    /// @notice Current spot price (token1 per token0, 1e18 scale). Changes with every trade.
    function spotPrice() public view returns (uint256) {
        return (reserve1 * 1e18) / reserve0;
    }

    /// @notice Cumulative price up to now, including the segment since the last trade.
    function currentCumulative() public view returns (uint256) {
        return priceCumulative + spotPrice() * (block.timestamp - lastUpdate);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function swap0For1(uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        amountOut = getAmountOut(amountIn, reserve0, reserve1);
        require(amountOut >= minAmountOut, "slippage");
        _update(); // record the old price for the elapsed time before reserves change
        token0.transferFrom(msg.sender, address(this), amountIn);
        token1.transfer(msg.sender, amountOut);
        reserve0 += amountIn;
        reserve1 -= amountOut;
    }

    function swap1For0(uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        amountOut = getAmountOut(amountIn, reserve1, reserve0);
        require(amountOut >= minAmountOut, "slippage");
        _update();
        token1.transferFrom(msg.sender, address(this), amountIn);
        token0.transfer(msg.sender, amountOut);
        reserve1 += amountIn;
        reserve0 -= amountOut;
    }

    function _update() internal {
        uint256 elapsed = block.timestamp - lastUpdate;
        if (elapsed > 0 && reserve0 > 0) {
            priceCumulative += spotPrice() * elapsed;
        }
        lastUpdate = block.timestamp;
    }
}
