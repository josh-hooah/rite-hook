// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntentSwapAdapter} from "../../src/interfaces/IIntentSwapAdapter.sol";

contract MockSwapAdapter is IIntentSwapAdapter {
    bool public shouldRevert;
    uint256 public nextAmountOut;
    address public reenterTarget;
    bytes public reenterCalldata;
    bool public lastReenterSuccess;

    function setRevert(bool enabled) external {
        shouldRevert = enabled;
    }

    function setAmountOut(uint256 amountOut) external {
        nextAmountOut = amountOut;
    }

    function setReenter(address target, bytes calldata callData) external {
        reenterTarget = target;
        reenterCalldata = callData;
    }

    function executeSwap(SwapRequest calldata request) external returns (uint256 amountOut) {
        if (shouldRevert) {
            revert("MOCK_REVERT");
        }

        IERC20(request.tokenIn).transferFrom(msg.sender, address(this), request.amountIn);

        if (reenterTarget != address(0)) {
            (lastReenterSuccess,) = reenterTarget.call(reenterCalldata);
        }

        amountOut = nextAmountOut;
        IERC20(request.tokenOut).transfer(request.recipient, amountOut);
    }
}
