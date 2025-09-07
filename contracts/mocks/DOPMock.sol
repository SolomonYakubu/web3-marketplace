// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract DOPMock is ERC20, ERC20Burnable {
    constructor(address to, uint256 supply) ERC20("DOP", "DOP") {
        _mint(to, supply);
    }
}
