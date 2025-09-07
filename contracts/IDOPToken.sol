// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IDOPToken {
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function burn(uint256 value) external;

    function burnFrom(address account, uint256 value) external;

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
}
