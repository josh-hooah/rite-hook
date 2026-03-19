// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookmateV4SwapAdapter} from "../../src/adapters/HookmateV4SwapAdapter.sol";
import {IIntentSwapAdapter} from "../../src/interfaces/IIntentSwapAdapter.sol";
import {ExecutionContext} from "../../src/libraries/IntentTypes.sol";
import {IntentEncoding} from "../../src/libraries/IntentEncoding.sol";
import {PriceCondition} from "../../src/libraries/PriceCondition.sol";
import {VolatilityMath} from "../../src/libraries/VolatilityMath.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract IntentLibraryHarness {
    function encodePayload(bytes32 intentId, uint256 nonce, ExecutionContext memory context)
        external
        pure
        returns (bytes memory)
    {
        return IntentEncoding.encodeExecuteIntentPayload(intentId, nonce, context);
    }

    function decodeContext(bytes calldata extra) external pure returns (ExecutionContext memory) {
        return IntentEncoding.decodeExecutionContext(extra);
    }

    function decodePayload(bytes calldata payload)
        external
        pure
        returns (address reactVM, bytes32 intentId, uint256 nonce, ExecutionContext memory context)
    {
        bytes4 selector = bytes4(payload[:4]);
        require(selector == bytes4(keccak256("executeIntent(address,bytes32,uint256,bytes)")), "bad selector");
        bytes memory extra;
        (reactVM, intentId, nonce, extra) = abi.decode(payload[4:], (address, bytes32, uint256, bytes));
        context = abi.decode(extra, (ExecutionContext));
    }

    function priceMeets(uint160 observed, uint160 target, bool priceAbove) external pure returns (bool) {
        return PriceCondition.meetsTarget(observed, target, priceAbove);
    }

    function tickToSqrt(int24 tick) external pure returns (uint160) {
        return PriceCondition.tickToSqrtPriceX96(tick);
    }

    function sqrtToPrice(uint160 sqrtPriceX96) external pure returns (uint256) {
        return PriceCondition.sqrtPriceX96ToPriceX128(sqrtPriceX96);
    }

    function rollingVol(uint32 previousVolatility, int24 previousTick, int24 currentTick, uint32 window)
        external
        pure
        returns (uint32)
    {
        return VolatilityMath.rollingAbsTickDelta(previousVolatility, previousTick, currentTick, window);
    }

    function volMeets(uint32 observed, uint32 threshold, bool above) external pure returns (bool) {
        return VolatilityMath.meetsThreshold(observed, threshold, above);
    }
}

contract MockPermit2Lite {
    uint256 public approveCallCount;
    address public lastToken;
    address public lastSpender;
    uint160 public lastAmount;
    uint48 public lastExpiration;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        approveCallCount += 1;
        lastToken = token;
        lastSpender = spender;
        lastAmount = amount;
        lastExpiration = expiration;
    }
}

contract MockRouterLite {
    int128 public nextAmount0;
    int128 public nextAmount1;
    uint256 public swapCallCount;

    function setDelta(int128 amount0, int128 amount1) external {
        nextAmount0 = amount0;
        nextAmount1 = amount1;
    }

    function swapExactTokensForTokens(
        uint256,
        uint256,
        bool,
        PoolKey calldata,
        bytes calldata,
        address,
        uint256
    ) external returns (BalanceDelta) {
        swapCallCount += 1;
        return toBalanceDelta(nextAmount0, nextAmount1);
    }
}

contract IntentLibsAndAdapterUnitTest is Test {
    HookmateV4SwapAdapter internal adapter;
    IntentLibraryHarness internal harness;
    MockRouterLite internal router;
    MockPermit2Lite internal permit2;

    MockERC20 internal token0;
    MockERC20 internal token1;

    PoolKey internal poolKey;

    address internal constant EXECUTOR = address(0xE7EC);
    address internal constant RECIPIENT = address(0xBEEFCAFE);

    function setUp() public {
        harness = new IntentLibraryHarness();
        router = new MockRouterLite();
        permit2 = new MockPermit2Lite();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        adapter = new HookmateV4SwapAdapter(
            address(this),
            /* router */ IUniswapV4Router04(payable(address(router))),
            /* permit2 */ IPermit2(address(permit2)),
            address(0xB0B0)
        );
        adapter.setExecutor(EXECUTOR);

        token0.mint(address(adapter), 1_000_000 ether);
        token1.mint(address(adapter), 1_000_000 ether);
        token0.mint(EXECUTOR, 1_000_000 ether);
        token1.mint(EXECUTOR, 1_000_000 ether);

        vm.prank(EXECUTOR);
        token0.approve(address(adapter), type(uint256).max);
        vm.prank(EXECUTOR);
        token1.approve(address(adapter), type(uint256).max);
    }

    function testIntentEncodingRoundTripAndPlaceholderReactVM() public {
        ExecutionContext memory context = ExecutionContext({
            observedSqrtPriceX96: 1234,
            observedTick: -10,
            observedVolatilityBps: 55,
            maxAmountIn: 42,
            hookData: hex"abcd"
        });

        bytes32 intentId = keccak256("intent");
        bytes memory payload = harness.encodePayload(intentId, 7, context);

        (address reactVM, bytes32 decodedIntentId, uint256 nonce, ExecutionContext memory decodedContext) =
            harness.decodePayload(payload);

        assertEq(reactVM, address(0));
        assertEq(decodedIntentId, intentId);
        assertEq(nonce, 7);
        assertEq(decodedContext.observedSqrtPriceX96, context.observedSqrtPriceX96);
        assertEq(decodedContext.observedTick, context.observedTick);
        assertEq(decodedContext.observedVolatilityBps, context.observedVolatilityBps);
        assertEq(decodedContext.maxAmountIn, context.maxAmountIn);
        assertEq(decodedContext.hookData, context.hookData);
    }

    function testIntentEncodingDecodeHandlesEmptyAndFilledContext() public {
        ExecutionContext memory emptyDecoded = harness.decodeContext("");
        assertEq(emptyDecoded.observedSqrtPriceX96, 0);
        assertEq(emptyDecoded.observedTick, 0);
        assertEq(emptyDecoded.observedVolatilityBps, 0);
        assertEq(emptyDecoded.maxAmountIn, 0);
        assertEq(emptyDecoded.hookData.length, 0);

        ExecutionContext memory context = ExecutionContext({
            observedSqrtPriceX96: 8_888,
            observedTick: 12,
            observedVolatilityBps: 77,
            maxAmountIn: 9,
            hookData: hex"1234"
        });
        ExecutionContext memory decoded = harness.decodeContext(abi.encode(context));
        assertEq(decoded.observedSqrtPriceX96, context.observedSqrtPriceX96);
        assertEq(decoded.observedTick, context.observedTick);
        assertEq(decoded.observedVolatilityBps, context.observedVolatilityBps);
        assertEq(decoded.maxAmountIn, context.maxAmountIn);
        assertEq(decoded.hookData, context.hookData);
    }

    function testPriceConditionHelpers() public {
        assertFalse(harness.priceMeets(0, 10, true));
        assertFalse(harness.priceMeets(10, 0, true));
        assertTrue(harness.priceMeets(10, 5, true));
        assertFalse(harness.priceMeets(4, 5, true));
        assertTrue(harness.priceMeets(4, 5, false));
        assertFalse(harness.priceMeets(6, 5, false));

        uint160 sqrtAtZeroTick = harness.tickToSqrt(0);
        assertEq(sqrtAtZeroTick, 79_228_162_514_264_337_593_543_950_336);

        uint256 priceX128 = harness.sqrtToPrice(sqrtAtZeroTick);
        assertEq(priceX128, 1 << 128);
    }

    function testVolatilityMathHelpers() public {
        assertEq(harness.rollingVol(50, 100, 98, 1), 2);
        assertEq(harness.rollingVol(50, 100, 98, 10), 45);

        assertFalse(harness.volMeets(50, 0, true));
        assertTrue(harness.volMeets(120, 100, true));
        assertFalse(harness.volMeets(80, 100, true));
        assertTrue(harness.volMeets(80, 100, false));
        assertFalse(harness.volMeets(120, 100, false));
    }

    function testFuzzPriceConditionMatchesExpected(uint160 observed, uint160 target, bool priceAbove) public {
        bool expected = target != 0 && observed != 0 && (priceAbove ? observed >= target : observed <= target);
        assertEq(harness.priceMeets(observed, target, priceAbove), expected);
    }

    function testFuzzVolatilityThresholdMatchesExpected(uint32 observed, uint32 threshold, bool above) public {
        bool expected = threshold != 0 && (above ? observed >= threshold : observed <= threshold);
        assertEq(harness.volMeets(observed, threshold, above), expected);
    }

    function testFuzzRollingVolatilityWindowOneIsAbsoluteDelta(int24 previousTick, int24 currentTick) public {
        uint32 actual = harness.rollingVol(123, previousTick, currentTick, 1);

        int256 diff = int256(previousTick) - int256(currentTick);
        if (diff < 0) {
            diff = -diff;
        }
        uint32 expected = uint32(uint256(diff));
        assertEq(actual, expected);
    }

    function testFuzzAdapterReturnsPositiveOutput(bool zeroForOne, int128 amount0, int128 amount1, uint96 amountIn) public {
        vm.assume(amountIn > 0);
        vm.assume(amountIn <= 1_000_000 ether);

        int128 selected = zeroForOne ? amount1 : amount0;
        vm.assume(selected > 0);
        vm.assume(selected <= int128(uint128(type(uint64).max)));

        router.setDelta(amount0, amount1);
        IIntentSwapAdapter.SwapRequest memory request = _buildRequest(
            zeroForOne ? address(token0) : address(token1),
            zeroForOne ? address(token1) : address(token0),
            zeroForOne,
            uint256(amountIn),
            1
        );

        vm.prank(EXECUTOR);
        uint256 out = adapter.executeSwap(request);
        assertEq(out, uint256(uint128(selected)));
    }

    function testAdapterSetExecutorOnlyOwnerAndUnauthorizedCallerReverts() public {
        vm.prank(address(0x1234));
        vm.expectRevert();
        adapter.setExecutor(address(0x5678));

        vm.expectRevert(HookmateV4SwapAdapter.ZeroExecutor.selector);
        adapter.setExecutor(address(0));

        IIntentSwapAdapter.SwapRequest memory request = _buildRequest(address(token0), address(token1), true, 1 ether, 1 ether);
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(HookmateV4SwapAdapter.UnauthorizedExecutor.selector, address(0xDEAD)));
        adapter.executeSwap(request);
    }

    function testAdapterConstructorRejectsZeroConfig() public {
        vm.expectRevert(HookmateV4SwapAdapter.InvalidConfig.selector);
        new HookmateV4SwapAdapter(address(this), IUniswapV4Router04(payable(address(0))), IPermit2(address(permit2)), address(1));

        vm.expectRevert(HookmateV4SwapAdapter.InvalidConfig.selector);
        new HookmateV4SwapAdapter(
            address(this), IUniswapV4Router04(payable(address(router))), IPermit2(address(0)), address(1)
        );

        vm.expectRevert(HookmateV4SwapAdapter.InvalidConfig.selector);
        new HookmateV4SwapAdapter(
            address(this), IUniswapV4Router04(payable(address(router))), IPermit2(address(permit2)), address(0)
        );
    }

    function testAdapterExecuteSwapSuccessAndApprovalCaching() public {
        router.setDelta(-1 ether, 2 ether);

        IIntentSwapAdapter.SwapRequest memory request = _buildRequest(address(token0), address(token1), true, 1 ether, 1);
        uint256 recipientBefore = token1.balanceOf(RECIPIENT);

        vm.prank(EXECUTOR);
        uint256 amountOut = adapter.executeSwap(request);

        assertEq(amountOut, 2 ether);
        assertEq(token1.balanceOf(RECIPIENT), recipientBefore + 2 ether);
        assertEq(permit2.approveCallCount(), 1);
        assertEq(router.swapCallCount(), 1);
        assertEq(token0.allowance(address(adapter), address(permit2)), type(uint256).max);

        router.setDelta(-1 ether, 3 ether);
        vm.prank(EXECUTOR);
        amountOut = adapter.executeSwap(request);

        assertEq(amountOut, 3 ether);
        assertEq(permit2.approveCallCount(), 1);
        assertEq(router.swapCallCount(), 2);
    }

    function testAdapterExecuteSwapSupportsOneForZeroDirection() public {
        router.setDelta(4 ether, -1 ether);

        IIntentSwapAdapter.SwapRequest memory request =
            _buildRequest(address(token1), address(token0), false, 1 ether, 1);
        uint256 recipientBefore = token0.balanceOf(RECIPIENT);

        vm.prank(EXECUTOR);
        uint256 amountOut = adapter.executeSwap(request);

        assertEq(amountOut, 4 ether);
        assertEq(token0.balanceOf(RECIPIENT), recipientBefore + 4 ether);
    }

    function testAdapterRevertsOnInvalidOutputDelta() public {
        router.setDelta(-1 ether, 0);
        IIntentSwapAdapter.SwapRequest memory request = _buildRequest(address(token0), address(token1), true, 1 ether, 1);

        vm.prank(EXECUTOR);
        vm.expectRevert(HookmateV4SwapAdapter.InvalidAmountOut.selector);
        adapter.executeSwap(request);
    }

    function _buildRequest(address tokenIn, address tokenOut, bool zeroForOne, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (IIntentSwapAdapter.SwapRequest memory)
    {
        return IIntentSwapAdapter.SwapRequest({
            intentId: keccak256("id"),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolKey: poolKey,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: minOut,
            hookData: bytes(""),
            recipient: RECIPIENT,
            deadline: block.timestamp + 1
        });
    }
}
