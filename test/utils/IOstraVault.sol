// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The parts of the live Ostra vault (version 3, github.com/ostraagent/ostra-robinhood, src/OstraVault.sol),
///         its factory and its beacon that these tests use. A vault moves funds only by WOTS spends; action 0 transfers its token,
///         action 23 approves a hash for EIP-1271.
interface IOstraVault {
    function VERSION() external view returns (uint8);
    function nonce() external view returns (uint64);
    function spendMessage(uint8 action, bytes32 nextKeyRoot, bytes calldata params) external view returns (bytes memory);
    function spend(uint8 action, bytes32 nextKeyRoot, bytes calldata params, bytes calldata signature) external;
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

interface IOstraVaultFactory {
    function createVault(address token, bytes32 initialKeyRoot, address initialCrank) external returns (address vault);
    function vaultAddress(address token, bytes32 initialKeyRoot, address initialCrank) external view returns (address);
}

interface IBeacon {
    function implementation() external view returns (address);
}
