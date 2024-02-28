// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./IFlashMintBorrower.sol";
import "./IEmployer.sol";
import "./ITimeIsUp.sol";
import "./ITimeToken.sol";
import "./Worker.sol";

// TODO: contrato receberá dividendos em TUP do Worker. Decidir o que será feito desses dividendos e como implementar alguma estratégia p/ otimizar o uso
contract Investor is IFlashMintBorrower {

    IEmployer private _employer;
    ITimeIsUp private _tup;
    ITimeToken private _timeToken;
    Worker private _worker;

    uint256 public amountTupFromWorker;

    constructor(Worker worker, ITimeToken timeToken, ITimeIsUp tup, IEmployer employer) {
        _worker = worker;
        _timeToken = timeToken;
        _tup = tup;
        _employer = employer;
    }

    receive() external payable { }

    fallback() external payable {
        require(msg.data.length == 0);
    }

    modifier onlyWorker() {
        require(msg.sender == address(_worker), "Investor: only Worker contract can perform this operation");
        _;
    }

    function addTup(uint256 amountTup) external onlyWorker {
        amountTupFromWorker += amountTup;
    }

    function doSomething(uint256 amountTup, uint256 fee, bytes calldata data) external {
        // TODO: verificar a viabilidade de fazer arbitragem com TUP via flash mint considerando o TIME e ETH disponível no contrato
    }

    // TODO: terminar essa função
    function harvest() external onlyWorker {
        uint256 earnedAmount;
        address(_worker).call{value: earnedAmount}("");
    }

    // TODO: ajustar essa função p/ retirar fundos de outros contratos, se houver
    function updateInvestor() external onlyWorker {
        _tup.transfer(address(_worker), _tup.balanceOf(address(this)));
        _timeToken.transfer(address(_worker), _timeToken.balanceOf(address(this)));
        payable(address(_worker)).transfer(address(this).balance);
    }
}