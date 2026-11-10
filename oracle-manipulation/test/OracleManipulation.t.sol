// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {InsecureLending} from "../src/InsecureLending.sol";
import {SecureLending} from "../src/SecureLending.sol";
import {MockFlashLender} from "../src/MockFlashLender.sol";
import {OracleAttacker} from "../src/OracleAttacker.sol";

contract OracleManipulationTest is Test {
    MockERC20 public token0; // collateral
    MockERC20 public token1; // borrow token
    SimpleAMM public amm;
    MockFlashLender public lender;
    InsecureLending public insecure;
    SecureLending public secure;
    OracleAttacker public insecureAttacker;
    OracleAttacker public secureAttacker;

    address supplier = makeAddr("supplier");
    address bob = makeAddr("bob");
    address whale = makeAddr("whale");

    uint256 constant FAIR_PRICE = 1000e18; // 1 token0 = 1000 token1 at setup

    function setUp() public {
        token0 = new MockERC20("Collateral", "COL");
        token1 = new MockERC20("Stable", "STB");
        amm = new SimpleAMM(address(token0), address(token1));
        lender = new MockFlashLender(address(token1));
        insecure = new InsecureLending(address(token0), address(token1), address(amm));
        insecureAttacker = new OracleAttacker(address(amm), address(insecure), address(lender));

        // Honest AMM liquidity: 100 token0 + 100,000 token1 => price 1000 token1 per token0
        token0.mint(address(this), 100e18);
        token1.mint(address(this), 100_000e18);
        token0.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);
        amm.addLiquidity(100e18, 100_000e18);

        // SecureLending reads the AMM's cumulative price in its constructor, which needs reserves to exist.
        // So it is deployed only after the liquidity above.
        secure = new SecureLending(address(token0), address(token1), address(amm));
        secureAttacker = new OracleAttacker(address(amm), address(secure), address(lender));

        // Flash lender liquidity
        token1.mint(address(lender), 1_000_000e18);

        // Supplier funds both lending markets with 150,000 token1 each
        token1.mint(supplier, 300_000e18);
        vm.startPrank(supplier);
        token1.approve(address(insecure), type(uint256).max);
        token1.approve(address(secure), type(uint256).max);
        insecure.supply(150_000e18);
        secure.supply(150_000e18);
        vm.stopPrank();

        // Each attacker posts 10 token0 as collateral at the fair price, and holds a
        // 10,000 token1 buffer to cover the round-trip AMM fee.
        token0.mint(address(insecureAttacker), 10e18);
        insecureAttacker.depositCollateral(10e18);
        token1.mint(address(insecureAttacker), 10_000e18);

        token0.mint(address(secureAttacker), 10e18);
        secureAttacker.depositCollateral(10e18);
        token1.mint(address(secureAttacker), 10_000e18);
    }

    // ---------------------------------------------------------------
    // 1. VULNERABLE: spot-price manipulation in one transaction
    // ---------------------------------------------------------------
    function test_Insecure_SpotManipulation_DrainsLender() public {
        uint256 bufferBefore = token1.balanceOf(address(insecureAttacker));

        // Flash-borrow 300,000 token1, borrow 100,000 against the pumped price, repay the flash loan
        insecureAttacker.attack(300_000e18, 100_000e18);

        // The attacker holds 100,000 token1 of debt, and collateral that is worth only 10,000 at fair price
        assertEq(insecure.debt(address(insecureAttacker)), 100_000e18);

        // The AMM price is back near fair after the dump (about 0.6% higher from fees kept in the pool)
        assertApproxEqRel(amm.spotPrice(), FAIR_PRICE, 0.01e18);

        // Attacker profit is the borrowed amount minus the round-trip AMM fee (about 99k)
        uint256 profit = token1.balanceOf(address(insecureAttacker)) - bufferBefore;
        assertGt(profit, 90_000e18);

        // Bad debt for suppliers: debt minus the collateral's fair value (10,000)
        uint256 fairCollateralValue = (10e18 * FAIR_PRICE) / 1e18;
        assertGt(insecure.debt(address(insecureAttacker)) - fairCollateralValue, 80_000e18);
    }

    // ---------------------------------------------------------------
    // 2. FIXED: the same attack reverts
    // ---------------------------------------------------------------
    function test_Secure_SameAttack_Reverts() public {
        // The TWAP needs a full window of history before it can be read
        vm.warp(block.timestamp + secure.TWAP_WINDOW());

        // Pump, borrow and dump all happen in one transaction, so the pumped price has zero seconds of weight
        vm.expectRevert("undercollateralized");
        secureAttacker.attack(300_000e18, 100_000e18);

        assertEq(secure.debt(address(secureAttacker)), 0);
    }

    // ---------------------------------------------------------------
    // 3. FIXED: a same-block price move does not change the TWAP at all
    // ---------------------------------------------------------------
    function test_Secure_SameBlockManipulation_DoesNotMoveTwap() public {
        vm.warp(block.timestamp + secure.TWAP_WINDOW());
        uint256 twapBefore = secure.twapPrice();
        assertEq(twapBefore, FAIR_PRICE);

        // A whale moves the AMM spot price up in the same block
        token1.mint(whale, 300_000e18);
        vm.startPrank(whale);
        token1.approve(address(amm), type(uint256).max);
        amm.swap1For0(300_000e18, 0);
        vm.stopPrank();

        assertGt(amm.spotPrice(), 15_000e18); // spot is pumped...
        assertEq(secure.twapPrice(), twapBefore); // ...but the TWAP has not moved
    }

    // ---------------------------------------------------------------
    // 4. FIXED: honest borrowing still works, and the limit is enforced
    // ---------------------------------------------------------------
    function test_Secure_HonestBorrow_Works() public {
        token0.mint(bob, 10e18);
        vm.startPrank(bob);
        token0.approve(address(secure), type(uint256).max);
        secure.depositCollateral(10e18);
        vm.stopPrank();

        vm.warp(block.timestamp + secure.TWAP_WINDOW());

        // 10 token0 at 1000 => 10,000 value, 75% factor => max debt 7,500
        vm.prank(bob);
        secure.borrow(7_000e18);
        assertEq(secure.debt(bob), 7_000e18);
        assertEq(token1.balanceOf(bob), 7_000e18);

        // Anything over the limit still reverts (7,000 + 600 = 7,600 > 7,500)
        vm.prank(bob);
        vm.expectRevert("undercollateralized");
        secure.borrow(600e18);
    }

    // ---------------------------------------------------------------
    // 5. LIMITATION: a TWAP raises the cost of manipulation but does not remove it.
    //    An attacker who holds the pumped price for the whole window, with real capital
    //    at risk, can still move the TWAP. This test documents that cost; it is not a bug.
    // ---------------------------------------------------------------
    function test_Secure_SustainedManipulation_StillMovesTwap() public {
        // Whale posts collateral at the fair price
        token0.mint(whale, 10e18);
        vm.startPrank(whale);
        token0.approve(address(secure), type(uint256).max);
        secure.depositCollateral(10e18);
        vm.stopPrank();

        // Whale holds 300,000 token1 of real capital and pumps the price
        vm.warp(block.timestamp + 1);
        token1.mint(whale, 300_000e18);
        vm.startPrank(whale);
        token1.approve(address(amm), type(uint256).max);
        amm.swap1For0(300_000e18, 0);
        vm.stopPrank();

        // The pumped price stays in place for a full window (no arbitrageur is modelled here)
        vm.warp(block.timestamp + secure.TWAP_WINDOW());

        // Now the TWAP has absorbed the pumped price and the borrow goes through
        vm.prank(whale);
        secure.borrow(100_000e18);
        assertEq(secure.debt(whale), 100_000e18);
    }
}
