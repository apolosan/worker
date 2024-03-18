// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ITimeToken } from "./ITimeToken.sol";

contract Minion {
    ITimeToken internal immutable _timeToken;
    address internal _coordinator;

    constructor(address coordinatorAddress, ITimeToken timeToken) {
        _coordinator = coordinatorAddress;
        _timeToken = timeToken;
    }

    function _produceTime() internal {
        _timeToken.mining();
        if (_coordinator != address(this)) {
            _timeToken.transfer(_coordinator, (_timeToken.balanceOf(address(this)) * 9_999) / 10_000);
        }
    }

    function enableMining() external payable returns (bool success) {
        require(msg.value > 0);
        try _timeToken.enableMining{ value: msg.value }() {
            success = true;
        } catch { }
        return success;
    }

    function produceTime() external {
        _produceTime();
    }

    function updateCoordinator(address newCoordinator) external {
        require(msg.sender == _coordinator, "Minion: only coordinator can call this function");
        _coordinator = newCoordinator;
    }
}
