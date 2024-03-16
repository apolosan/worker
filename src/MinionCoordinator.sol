// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Minion, ITimeToken } from "./Minion.sol";
import { Worker } from "./Worker.sol";

contract MinionCoordinator {

    struct MinionInstance {
        address prevInstance;
        address nextInstance;
    }

    bool private _isOperationLocked;

    Worker private _worker;

    address public firstMinionInstance;
    address public lastMinionInstance;

    uint256 public constant MAX_NUMBER_OF_MINIONS = 20_000;    

    uint256 public activeMinions;
    uint256 public dedicatedAmount;
    uint256 public timeProduced;

    mapping(address => uint256) private _currentBlock;

    mapping(address => MinionInstance instance) public minions;
    mapping(address => uint256) public blockToUnlock;

    constructor(Worker worker) {
        _worker = worker;
    }

    /// @notice Modifier used to avoid reentrancy attacks
    modifier nonReentrant() {
        require(!_isOperationLocked, "Coordinator: this operation is locked for security reasons");
        _isOperationLocked = true;
        _;
        _isOperationLocked = false;
    }

    /// @notice Modifier to make a function runs only once per block (also avoids reentrancy, but in a different way)
    modifier onlyOncePerBlock() {
        require(block.number != _currentBlock[tx.origin], "Coordinator: you cannot perform this operation again in this block");
        _currentBlock[tx.origin] = block.number;
        _;
    }    

    /// @notice Modifier used to allow function calling only by Worker contract
    modifier onlyWorker() {
        require(msg.sender == address(_worker), "Coordinator: only Worker contract can perform this operation");
        _;
    }

    /// @notice Registers a Minion in the contract
    /// @dev Add an instance of the Minion contract into the internal linked list of the Worker contract. It also adjusts information about previous instances registered
    /// @param minion The instance of the recently created Minion contract
    function _addMinionInstance(Minion minion) private {
        if (lastMinionInstance != address(0)) {
            minions[lastMinionInstance].nextInstance = address(minion);
        }
        minions[address(minion)].prevInstance = lastMinionInstance;
        minions[address(minion)].nextInstance = address(0);
        if (firstMinionInstance == address(0)) {
            firstMinionInstance = address(minion);
        }
        lastMinionInstance = address(minion);
    }
    
    /// @notice Creates one Minion given a dedicated amount provided
    /// @dev Creates an instance of the Minion contract, registers it into the contract, and activates it for TIME token production
    /// @param dedicatedAmountForFee The dedicated amount for creation of the new Minion instance
    /// @return newDedicatedAmountForFee The remaining from dedicated amount after Minion creation
    /// @return success Returns true if the Minion was created correctly
    function _createMinionInstance(uint256 dedicatedAmountForFee) private returns (uint256 newDedicatedAmountForFee, bool success) {
        uint256 fee = ITimeToken(_worker.timeToken()).fee();
        if (fee <= dedicatedAmountForFee && activeMinions < MAX_NUMBER_OF_MINIONS) {
            Minion minionInstance = new Minion(address(this), _worker.timeToken());
            try minionInstance.enableMining{ value: fee }() returns (bool enableSuccess) {
                _addMinionInstance(minionInstance);
                activeMinions++;
                newDedicatedAmountForFee = dedicatedAmountForFee - fee;
                success = enableSuccess;
            } catch { }
        }
    }

    /// @notice Creates several Minions from a given amount of fee dedicated for the task
    /// @dev It iterates over the amount of fee dedicated for Minion activation until this value goes to zero, the number of active Minions reach the maximum level, or it reverts for some cause
    /// @param totalFeeForCreation The native amount dedicated for Minion activation for TIME production
    function _createMinions(uint256 totalFeeForCreation) private {
        require(totalFeeForCreation <= address(this).balance, "Coordinator: there is no enough amount for enabling minion activation for TIME production");
        bool success;
        do {
            (totalFeeForCreation, success) = _createMinionInstance(totalFeeForCreation);
        } while (totalFeeForCreation > 0 && success);
    }

    /// @notice Performs production of TIME token
    /// @dev It calls the mining() function of TIME token from all active Minions' instances
    /// @return amountTime The amount of TIME tokens produced
    function _work() private returns (uint256 amountTime) {
        uint256 timeBalanceBeforeWork = ITimeToken(_worker.timeToken()).balanceOf(address(this));
        address currentMinionInstance = firstMinionInstance;
        do {
            Minion(currentMinionInstance).produceTime();
            currentMinionInstance = minions[currentMinionInstance].nextInstance;
        } while (currentMinionInstance != address(0));
        uint256 timeBalanceAfterWork = ITimeToken(_worker.timeToken()).balanceOf(address(this));
        amountTime = (timeBalanceAfterWork - timeBalanceBeforeWork);
        timeProduced += amountTime;
        ITimeToken(_worker.timeToken()).transfer(address(_worker), amountTime);
        return amountTime;
    }    

    /// @notice Receive specific resources coming from Worker to create new Minions
    /// @dev It should be called only by the Worker contract
    /// @return success Informs if the function was called and executed correctly
    function addResourcesForMinionCreation() payable external onlyWorker returns (bool success) {
        if (msg.value > 0) {
            dedicatedAmount += msg.value;
            success = true;
        }
        return success;
    }

    /// @notice The Worker contract calls this function to create Minions on demand given some amount of native tokens paid/passed (msg.value parameter)
    /// @dev It performs some additional checks and redirects to the _createMinions() function
    /// @return numberOfMinionsCreated The number of active Minions created for TIME production
    function createMinions() payable external onlyWorker returns (uint256 numberOfMinionsCreated) {
        require(msg.value > 0, "Coordinator: please send some native tokens to create minions");
        numberOfMinionsCreated = activeMinions;
        _createMinions(msg.value);
        if (dedicatedAmount > 0) {
            _createMinions(dedicatedAmount);
            dedicatedAmount = 0;
        }
        numberOfMinionsCreated = activeMinions - numberOfMinionsCreated;
        if (numberOfMinionsCreated == 0)
            revert("Coordinator: the amount sent is not enough to create and activate new minions for TIME production");
        return numberOfMinionsCreated;
    }

    /// @notice When a new MinionCoordinator is created, this function transfers control over all Minions already created to it
    /// @dev It iterates over all Minions and copy all references of them from the old to the new MinionCoordinator contract. This function can be called only by the Worker contract
    /// @param oldCoordinator Instance of the old MinionCoordinator
    function transferMinionsBetweenCoordinators(MinionCoordinator oldCoordinator) external onlyWorker {
        firstMinionInstance = oldCoordinator.firstMinionInstance();
        lastMinionInstance = oldCoordinator.lastMinionInstance();
        address currentMinionInstance = firstMinionInstance;
        do {
            (address prevInstance, address nextInstance) = oldCoordinator.minions(currentMinionInstance);
            minions[currentMinionInstance].prevInstance = prevInstance;
            minions[currentMinionInstance].nextInstance = nextInstance;
            currentMinionInstance = nextInstance;
        } while (currentMinionInstance != address(0));
    }

    /// @notice Updates the new MinionCoordinator on all Minion instances
    /// @dev It must be called externally by the Worker contract only, and after calling the transferMinionsBetweenCoordinators() function
    /// @param newCoordinator Instance of the new MinionCoordinator contract
    function updateCoordinator(MinionCoordinator newCoordinator) external onlyWorker {
        address currentMinionInstance = firstMinionInstance;
        do {
            Minion(currentMinionInstance).updateCoordinator(address(newCoordinator));
            currentMinionInstance = minions[currentMinionInstance].nextInstance;
        } while (currentMinionInstance != address(0));
    }

    /// @notice Call the Coordinator contract to produce TIME tokens
    /// @dev Can be called only by the Worker contract
    function work() external onlyWorker returns (uint256 producedTime) {
        return _work();
    }
}