pragma solidity ^0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";

interface IAToken is IERC20 {
    //function transferFrom(address from, address to, uint256 amount) external;

    function redeem(uint256 _amount) external;
}
