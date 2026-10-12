// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Dead Drop (DROP) launch token
/// @notice Fixed-supply ERC-20. The whole supply, 1,000,000,000 DROP at 18 decimals, is minted
///         once to the deployer (the launch factory), which splits it under the launch policy.
///         Plain transfers only: no mint, owner, pause, blocklist, fee or upgrade functions.
contract LaunchToken is ERC20 {
    /// @notice 1,000,000,000 tokens at 18 decimals.
    uint256 public constant SUPPLY = 1_000_000_000e18;

    constructor() ERC20("Dead Drop", "DROP") {
        _mint(msg.sender, SUPPLY);
    }
}
