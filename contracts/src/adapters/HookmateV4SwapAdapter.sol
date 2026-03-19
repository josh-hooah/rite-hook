// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {IIntentSwapAdapter} from "../interfaces/IIntentSwapAdapter.sol";

/// @notice Swap adapter that executes intent swaps through a Uniswap v4-compatible router.
contract HookmateV4SwapAdapter is IIntentSwapAdapter, Ownable {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    error InvalidConfig();
    error ZeroExecutor();
    error UnauthorizedExecutor(address caller);
    error InvalidAmountOut();

    event ExecutorUpdated(address indexed executor);

    IUniswapV4Router04 public immutable router;
    IPermit2 public immutable permit2;
    address public immutable poolManager;
    address public executor;

    mapping(address => bool) private _tokenApprovalInitialized;

    constructor(address initialOwner, IUniswapV4Router04 router_, IPermit2 permit2_, address poolManager_)
        Ownable(initialOwner)
    {
        if (address(router_) == address(0) || address(permit2_) == address(0) || poolManager_ == address(0)) {
            revert InvalidConfig();
        }
        router = router_;
        permit2 = permit2_;
        poolManager = poolManager_;
    }

    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) {
            revert ZeroExecutor();
        }
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    function executeSwap(SwapRequest calldata request) external returns (uint256 amountOut) {
        if (msg.sender != executor) {
            revert UnauthorizedExecutor(msg.sender);
        }

        IERC20(request.tokenIn).safeTransferFrom(msg.sender, address(this), request.amountIn);
        _ensureApprovals(request.tokenIn);

        BalanceDelta delta = router.swapExactTokensForTokens({
            amountIn: request.amountIn,
            amountOutMin: request.amountOutMin,
            zeroForOne: request.zeroForOne,
            poolKey: request.poolKey,
            hookData: request.hookData,
            receiver: address(this),
            deadline: request.deadline
        });

        int128 outputDelta = request.zeroForOne ? delta.amount1() : delta.amount0();
        if (outputDelta <= 0) {
            revert InvalidAmountOut();
        }

        amountOut = uint256(uint128(outputDelta));
        IERC20(request.tokenOut).safeTransfer(request.recipient, amountOut);
    }

    function _ensureApprovals(address token) internal {
        if (_tokenApprovalInitialized[token]) {
            return;
        }

        IERC20(token).forceApprove(address(permit2), type(uint256).max);
        IERC20(token).forceApprove(address(router), type(uint256).max);
        permit2.approve(token, poolManager, type(uint160).max, type(uint48).max);

        _tokenApprovalInitialized[token] = true;
    }
}
