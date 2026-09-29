// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "../utils/Deployers.sol";
import {SolvencyHandler} from "./SolvencyHandler.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IHooks} from "../../src/interfaces/IHooks.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {PoolId} from "../../src/types/PoolId.sol";
import {Currency} from "../../src/types/Currency.sol";
import {ModifyLiquidityParams} from "../../src/types/PoolOperation.sol";
import {StateLibrary} from "../../src/libraries/StateLibrary.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";
import {FixedPoint128} from "../../src/libraries/FixedPoint128.sol";
import {LiquidityAmounts} from "../utils/LiquidityAmounts.sol";
import {FullMath} from "../../src/libraries/FullMath.sol";
import {ProtocolFees} from "../../src/ProtocolFees.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Stateful invariant campaign: random valid operations must never make the
/// PoolManager insolvent. The manager must always hold at least the sum of every
/// obligation in each currency — the withdrawable principal + accrued fees of every
/// open position, plus accrued protocol fees. A violation is a real theft/insolvency bug.
contract SolvencyInvariantTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    SolvencyHandler handler;
    PoolId poolId;

    // tolerance (wei) per currency to absorb benign rounding: removal rounds in the
    // pool's favor, and getAmountsForLiquidity rounds down, so obligations are a slight
    // UNDER-estimate of the real balance — a comfortable margin here means a failure is real.
    uint256 constant TOL = 1000;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        // seed baseline liquidity so swaps/donates have something to work with.
        // Range [-3000,3000] is intentionally DISTINCT from every handler range (no double-count).
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -3000, tickUpper: 3000, liquidityDelta: 1e21, salt: 0}), ZERO_BYTES
        );

        handler = new SolvencyHandler(manager, swapRouter, modifyLiquidityRouter, donateRouter, key);

        // fund the handler generously in both currencies
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 1e30);

        // Only fuzz the handler's action functions.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = SolvencyHandler.addLiquidity.selector;
        selectors[1] = SolvencyHandler.removeLiquidity.selector;
        selectors[2] = SolvencyHandler.swap.selector;
        selectors[3] = SolvencyHandler.swapExactOut.selector;
        selectors[4] = SolvencyHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Validity check (not an invariant): right after seeding, the computed
    /// obligations must ACCOUNT FOR essentially the entire manager balance. If they
    /// didn't, the solvency invariant would pass vacuously. This proves it is tight.
    function test_obligationsAreTight_afterSeed() public view {
        (uint256 s0, uint256 s1) = _positionValue(-3000, 3000);
        uint256 bal0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(manager));
        uint256 bal1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(manager));
        // balance and obligation must match within a few wei of rounding
        assertApproxEqAbs(s0, bal0, 5, "obligation0 does not track balance (invariant would be vacuous)");
        assertApproxEqAbs(s1, bal1, 5, "obligation1 does not track balance (invariant would be vacuous)");
    }

    /// @notice The manager must always be solvent against all obligations.
    function invariant_managerSolvent() public view {
        (uint256 owed0, uint256 owed1) = _totalObligations();

        // include the baseline seed position (owned by modifyLiquidityRouter, range [-3000,3000])
        (uint256 s0, uint256 s1) = _positionValue(-3000, 3000);
        owed0 += s0;
        owed1 += s1;

        owed0 += ProtocolFees(address(manager)).protocolFeesAccrued(currency0);
        owed1 += ProtocolFees(address(manager)).protocolFeesAccrued(currency1);

        uint256 bal0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(manager));
        uint256 bal1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(manager));

        assertLe(owed0, bal0 + TOL, "INSOLVENT currency0: obligations exceed manager balance");
        assertLe(owed1, bal1 + TOL, "INSOLVENT currency1: obligations exceed manager balance");
    }

    function _totalObligations() internal view returns (uint256 owed0, uint256 owed1) {
        uint256 n = handler.rangeCount();
        for (uint256 i = 0; i < n; i++) {
            (int24 lower, int24 upper, bool used) = handler.rangeAt(i);
            if (!used) continue;
            (uint256 a0, uint256 a1) = _positionValue(lower, upper);
            owed0 += a0;
            owed1 += a1;
        }
    }

    /// @dev value of the position owned by the modify-liquidity router at [lower,upper]:
    /// principal (getAmountsForLiquidity) + fees owed since last checkpoint.
    function _positionValue(int24 lower, int24 upper) internal view returns (uint256 amt0, uint256 amt1) {
        (uint128 liquidity, uint256 fg0Last, uint256 fg1Last) =
            manager.getPositionInfo(poolId, address(modifyLiquidityRouter), lower, upper, bytes32(0));
        if (liquidity == 0) return (0, 0);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        (amt0, amt1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liquidity
        );

        (uint256 fg0, uint256 fg1) = manager.getFeeGrowthInside(poolId, lower, upper);
        unchecked {
            // fee-growth delta wraps (mod 2^256) by design; mulDiv matches Pool/Position math
            amt0 += FullMath.mulDiv(fg0 - fg0Last, liquidity, FixedPoint128.Q128);
            amt1 += FullMath.mulDiv(fg1 - fg1Last, liquidity, FixedPoint128.Q128);
        }
    }
}
