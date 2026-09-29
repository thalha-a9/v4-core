// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IHooks} from "../../src/interfaces/IHooks.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {Currency} from "../../src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "../../src/types/PoolOperation.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";
import {StateLibrary} from "../../src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "../../src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "../../src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "../../src/test/PoolDonateTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Drives random, valid v4 operations against a single pool to stress the
/// solvency invariant. Every action is wrapped in try/catch so a bounded-but-still-
/// rejected input (e.g. a swap hitting the price limit) doesn't waste a fuzz run.
contract SolvencyHandlerV2 is CommonBase, StdCheats, StdUtils {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable modifyRouter;
    PoolDonateTest public immutable donateRouter;
    PoolKey public key;

    int24 constant TICK_SPACING = 60;

    // Distinct liquidity ranges the handler can touch (aligned to tick spacing).
    int24[4] LOWERS = [int24(-600), int24(-1200), int24(-6000), int24(-60)];
    int24[4] UPPERS = [int24(600), int24(1200), int24(6000), int24(60)];

    // ghost: ranges that have ever been added to (so the invariant can enumerate positions)
    bool[4] public touched;

    uint256 public calls;

    constructor(
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _modifyRouter,
        PoolDonateTest _donateRouter,
        PoolKey memory _key
    ) {
        manager = _manager;
        swapRouter = _swapRouter;
        modifyRouter = _modifyRouter;
        donateRouter = _donateRouter;
        key = _key;

        MockERC20(Currency.unwrap(_key.currency0)).approve(address(_swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(_key.currency1)).approve(address(_swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(_key.currency0)).approve(address(_modifyRouter), type(uint256).max);
        MockERC20(Currency.unwrap(_key.currency1)).approve(address(_modifyRouter), type(uint256).max);
        MockERC20(Currency.unwrap(_key.currency0)).approve(address(_donateRouter), type(uint256).max);
        MockERC20(Currency.unwrap(_key.currency1)).approve(address(_donateRouter), type(uint256).max);
    }

    function rangeCount() external pure returns (uint256) {
        return 4;
    }

    function rangeAt(uint256 i) external view returns (int24 lower, int24 upper, bool used) {
        return (LOWERS[i], UPPERS[i], touched[i]);
    }

    function addLiquidity(uint256 rangeSeed, uint128 liqSeed) external {
        calls++;
        uint256 idx = rangeSeed % 4;
        int128 liq = int128(int256(bound(liqSeed, 1e12, 1e24)));
        try modifyRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: LOWERS[idx], tickUpper: UPPERS[idx], liquidityDelta: liq, salt: 0}),
            ""
        ) {
            touched[idx] = true;
        } catch {}
    }

    function removeLiquidity(uint256 rangeSeed, uint128 liqSeed) external {
        calls++;
        uint256 idx = rangeSeed % 4;
        (uint128 current,,) =
            manager.getPositionInfo(key.toId(), address(modifyRouter), LOWERS[idx], UPPERS[idx], bytes32(0));
        if (current == 0) return;
        int128 liq = int128(int256(bound(liqSeed, 1, current)));
        try modifyRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: LOWERS[idx], tickUpper: UPPERS[idx], liquidityDelta: -liq, salt: 0}),
            ""
        ) {} catch {}
    }

    function swap(bool zeroForOne, uint256 amountSeed, bool takeClaims) external {
        calls++;
        int256 amt = -int256(bound(amountSeed, 1e6, 1e21)); // exact-in
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amt, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: takeClaims, settleUsingBurn: false}),
            ""
        ) {} catch {}
    }

    function swapExactOut(bool zeroForOne, uint256 amountSeed, bool takeClaims) external {
        calls++;
        int256 amt = int256(bound(amountSeed, 1e6, 1e20)); // exact-out (positive)
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amt, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: takeClaims, settleUsingBurn: false}),
            ""
        ) {} catch {}
    }

    function donate(uint256 amt0Seed, uint256 amt1Seed) external {
        calls++;
        uint256 a0 = bound(amt0Seed, 0, 1e20);
        uint256 a1 = bound(amt1Seed, 0, 1e20);
        try donateRouter.donate(key, a0, a1, "") {} catch {}
    }
}
