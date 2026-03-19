// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library VolatilityMath {
    function rollingAbsTickDelta(uint32 previousVolatility, int24 previousTick, int24 currentTick, uint32 window)
        internal
        pure
        returns (uint32)
    {
        uint32 absDelta = _absDelta(previousTick, currentTick);
        if (window <= 1) {
            return absDelta;
        }

        uint256 weighted = uint256(previousVolatility) * (window - 1);
        return uint32((weighted + absDelta) / window);
    }

    function meetsThreshold(uint32 observedVolatilityBps, uint32 thresholdBps, bool above) internal pure returns (bool) {
        if (thresholdBps == 0) {
            return false;
        }
        return above ? observedVolatilityBps >= thresholdBps : observedVolatilityBps <= thresholdBps;
    }

    function _absDelta(int24 a, int24 b) private pure returns (uint32) {
        int256 diff = int256(a) - int256(b);
        if (diff < 0) {
            diff = -diff;
        }
        return uint32(uint256(diff));
    }
}
