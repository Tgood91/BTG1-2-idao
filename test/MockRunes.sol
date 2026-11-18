// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockRunes (TESTNET ONLY)
/// @notice Stand-in for Runes on Base Sepolia, where the real Runes does not exist. 18 decimals like Runes.
/// Anyone can mint: it has no value and must never be deployed to mainnet.
contract MockRunes is ERC20 {
    constructor() ERC20("Test Runes", "tRUNES") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
