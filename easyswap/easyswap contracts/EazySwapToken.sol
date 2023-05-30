// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract EazySwapToken is ERC20Burnable, Ownable {
    uint256 internal constant MAX_TOTAL_SUPPLY = 500_000 ether; // 500k max supply

    constructor() ERC20("EazySwap Token", "EAZY") {
        _mint(msg.sender, 1000 ether); // 1k for initial liquidity
    }

    function mint(address to, uint256 amount) public onlyOwner {
        require(
            amount + totalSupply() <= MAX_TOTAL_SUPPLY,
            "EazySwapToken: nooo"
        );
        _mint(to, amount);
    }

    function getMaxTotalSupply() external pure returns (uint256) {
        return MAX_TOTAL_SUPPLY;
    }
}
