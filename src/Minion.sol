// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./ITimeToken.sol";

contract Minion {
    ITimeToken private immutable timeToken;
    address private coordinator;

    constructor(address coordinatorAddress, ITimeToken timeToken_) {
        timeToken = timeToken_;
        coordinator = coordinatorAddress;
    }

    function enableMining() external payable returns (bool success) {
        require(msg.value > 0);
        try timeToken.enableMining{ value: msg.value }() {
            success = true;
        } catch { }
        return success;
    }

    function produceTime() external {
        timeToken.mining();
        timeToken.transfer(coordinator, (timeToken.balanceOf(address(this)) * 9_999) / 10_000);
    }

    function updateCoordinator(address newCoordinator) external {
        require(msg.sender == coordinator, "Minion: only coordinator can call this function");
        coordinator = newCoordinator;
    }
}
