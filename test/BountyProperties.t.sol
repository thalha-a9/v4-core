// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "./utils/Deployers.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {IHooks} from "../src/interfaces/IHooks.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {PoolId} from "../src/types/PoolId.sol";
import {Currency} from "../src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "../src/types/PoolOperation.sol";
import {BalanceDelta} from "../src/types/BalanceDelta.sol";
import {PoolSwapTest} from "../src/test/PoolSwapTest.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Property tests probing the invariants that back the "no theft / no
/// insolvency / no free value from rounding" claims in notes/AUDIT.md.
/// These are due-diligence checks: each encodes a way the protocol *could* be
/// robbed, and asserts it cannot be. A failing test would be a real finding.
contract BountyPropertiesTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
    }

    /// P1: With a 0-fee pool, a swap in then a swap back of everything received
    /// must NOT return more of the input token than you started with. If it did,
    /// rounding would be minting value out of thin air (drainable in a loop).
    function testFuzz_noValueCreation_roundTrip_zeroFee(uint128 amountIn) public {
        amountIn = uint128(bound(amountIn, 1e6, 1e24));

        (key,) = initPool(currency0, currency1, IHooks(address(0)), 0, int24(60), SQRT_PRICE_1_1);
        // deep, wide liquidity so we stay well inside one price region
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e27, salt: 0}), ZERO_BYTES
        );

        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));

        uint256 start0 = t0.balanceOf(address(this));
        uint256 start1 = t1.balanceOf(address(this));

        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // exact-in: sell `amountIn` of token0 for token1
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(uint256(amountIn)), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ts,
            ZERO_BYTES
        );
        uint256 got1 = t1.balanceOf(address(this)) - start1;
        require(got1 > 0, "no output");

        // exact-in: sell everything we just received back for token0
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(got1), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            ts,
            ZERO_BYTES
        );

        uint256 end0 = t0.balanceOf(address(this));
        // Must not have created value: you can only get back <= what you put in.
        assertLe(end0, start0, "ROUNDING CREATED VALUE (potential drain)");
    }

    /// P2: Solvency after a full unlock cycle. The manager must always hold at
    /// least the sum of currency it owes (pool principal + accrued fees). We
    /// approximate the strongest observable form: after all deltas settle,
    /// the manager's token balance covers the reserves implied by outstanding
    /// liquidity. Concretely: an LP who is the ONLY liquidity provider can always
    /// withdraw everything (principal + fees) — the pool can't become insolvent
    /// against its sole LP.
    function testFuzz_soleLP_canAlwaysFullyWithdraw(uint128 amountIn, bool zeroForOne) public {
        amountIn = uint128(bound(amountIn, 1e6, 1e21));

        (key,) = initPool(currency0, currency1, IHooks(address(0)), 3000, int24(60), SQRT_PRICE_1_1);

        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e24, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(key, addParams, ZERO_BYTES);

        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Someone swaps against the pool (a different actor's tokens/effect).
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(amountIn)),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            ts,
            ZERO_BYTES
        );

        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 mgr0 = t0.balanceOf(address(manager));
        uint256 mgr1 = t1.balanceOf(address(manager));

        // Sole LP removes ALL liquidity — this must succeed and pay out, and the
        // manager must have had the tokens to pay (no insolvency).
        ModifyLiquidityParams memory removeParams =
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: -1e24, salt: 0});
        BalanceDelta d = modifyLiquidityRouter.modifyLiquidity(key, removeParams, ZERO_BYTES);

        // The manager paid the LP; balances can't have gone negative (would revert),
        // and what it paid out was covered by what it held.
        // amount0/amount1 of delta are what the LP received (positive) or paid.
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (a0 > 0) assertLe(uint128(a0), mgr0, "insolvent in token0");
        if (a1 > 0) assertLe(uint128(a1), mgr1, "insolvent in token1");
    }
}
