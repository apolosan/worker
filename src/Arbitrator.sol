// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBeefyVault, IERC20Upgradeable } from "@beefy/keepers/interfaces/IBeefyVault.sol";
import { IBeefyStrategy } from "@beefy/keepers/interfaces/IBeefyStrategy.sol";
import { IUniswapV2Factory } from "./IUniswapV2Factory.sol";
import { IUniswapV2Router02 } from "./IUniswapV2Router02.sol";
import { IFlashMintBorrower } from "./IFlashMintBorrower.sol";
import { ISponsor, ITimeIsUp, Math, Ownable, Worker } from "./Worker.sol";
import { Minion, ITimeToken } from "./Minion.sol";

contract Arbitrator is IFlashMintBorrower {
    constructor() { }

    function doSomething(uint256 amountTup, uint256 fee, bytes calldata data) external {
        // TODO: verificar a viabilidade de fazer arbitragem com TUP via flash mint considerando o TIME e ETH disponível no contrato
    }
}
