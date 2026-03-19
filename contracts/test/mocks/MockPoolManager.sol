// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockPoolManager {
    mapping(bytes32 => bytes32) internal _slots;

    uint256 internal constant POOLS_SLOT = 6;

    function setSlot0(bytes32 poolId, uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) external {
        bytes32 slot = keccak256(abi.encode(poolId, bytes32(POOLS_SLOT)));

        uint256 packed = uint256(sqrtPriceX96);
        packed |= uint256(uint24(uint24(tick))) << 160;
        packed |= uint256(protocolFee) << 184;
        packed |= uint256(lpFee) << 208;

        _slots[slot] = bytes32(packed);
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }
}
