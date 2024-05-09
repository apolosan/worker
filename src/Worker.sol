// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IWorker, MinionCoordinator } from "./MinionCoordinator.sol";
import { ITimeToken } from "./ITimeToken.sol";
import { ITimeIsUp } from "./ITimeIsUp.sol";
import { IEmployer } from "./IEmployer.sol";
import { ISponsor } from "./ISponsor.sol";
// import { Investor, VaultInvestor } from "./VaultInvestor.sol";

contract Worker is Ownable, IWorker {
    using Math for uint256;

    bool private _isOperationLocked;

    // Investor public investor;
    MinionCoordinator public minionCoordinator;
    ITimeToken public timeToken;
    ITimeIsUp public tup;

    address public constant DONATION_ADDRESS = 0xbF616B8b8400373d53EC25bB21E2040adB9F927b;

    uint256 public constant DONATION_FEE = 50;
    uint256 public constant CALLER_FEE = 50;
    uint256 public constant FACTOR = 10 ** 18;
    uint256 public constant INVESTMENT_FEE = 60;
    uint256 public constant MAX_PERCENTAGE_ALLOCATION_OF_TIME = 4_900;
    uint256 public constant MINION_CREATION_FEE = 100;

    uint256 private _callerComission;
    uint256 private _dividendPerToken;

    uint256 public baseTimeFrame;
    uint256 public earnedAmount;
    uint256 public totalAdditionalTupFromInvestor;
    uint256 public totalDepositedTup;

    mapping(address => uint256) private _consumedDividendPerToken;
    mapping(address => uint256) private _currentBlock;

    mapping(address => uint256) public availableTimeAsCaller;
    mapping(address => uint256) public depositedTup;
    mapping(address => uint256) public blockToUnlock;

    constructor(address timeTokenAddress, address tupAddress, address employerAddress, address sponsorAddress) Ownable(msg.sender) {
        timeToken = ITimeToken(payable(timeTokenAddress));
        tup = ITimeIsUp(payable(tupAddress));
        IEmployer employer = IEmployer(payable(employerAddress));
        ISponsor sponsor = ISponsor(payable(sponsorAddress));
        // investor = new VaultInvestor(msg.sender, this, timeToken, tup, sponsor);
        minionCoordinator = new MinionCoordinator(this);
        baseTimeFrame = employer.ONE_YEAR().mulDiv(1, employer.D().mulDiv(365, 1));
    }

    receive() external payable {
        if (msg.value > 0) {
            _addEarningsAndCalculateDividendPerToken(msg.value);
        }
    }

    fallback() external payable {
        require(msg.data.length == 0);
        if (msg.value > 0) {
            _addEarningsAndCalculateDividendPerToken(msg.value);
        }
    }

    /// @notice Modifier used to avoid reentrancy attacks
    modifier nonReentrant() {
        require(!_isOperationLocked, "Worker: this operation is locked for security reasons");
        _isOperationLocked = true;
        _;
        _isOperationLocked = false;
    }

    /// @notice Modifier to make a function runs only once per block (also avoids reentrancy, but in a different way)
    modifier onlyOncePerBlock() {
        require(block.number != _currentBlock[tx.origin], "Worker: you cannot perform this operation again in this block");
        _currentBlock[tx.origin] = block.number;
        _;
    }

    // /// @notice Modifier used to allow function calling only by Investor contract
    // modifier onlyInvestor() {
    //     require(msg.sender == address(investor), "Worker: only Investor contract can perform this operation");
    //     _;
    // }

    /// @notice Add the earned amount from this contract at the moment into the total earned amount (historic) and calculates the dividend per TUP token holders
    /// @param earned The amount earned from this contract at the moment
    function _addEarningsAndCalculateDividendPerToken(uint256 earned) private {
        uint256 currentCallerComission = earned.mulDiv(CALLER_FEE, 10_000);
        _callerComission += currentCallerComission;
        earned -= currentCallerComission;
        earnedAmount += earned;
        _dividendPerToken += earned.mulDiv(FACTOR, totalDepositedTup + 1);
    }

    /// @notice Dedicate some TUP tokens for investments which should add value to the whole platform and will be distributed to users
    /// @dev Approve and transfer TUP to Investor contract
    /// @param amountTup The amount of TUP tokens to be transferred to Investor
    function _addTupToInvest(uint256 amountTup) private {
        // tup.approve(address(investor), amountTup);
        // // try investor.addTupToInvest(amountTup) { } catch { }
        // if (investor.totalSupply() > 0) {
        //     try investor.deposit(amountTup, address(this)) { } catch { }
        // } else {
        //     try investor.mint(amountTup, address(this)) { } catch { }
        // }
    }

    /// @notice Defines for how long the TUP token of the user should be locked
    /// @dev It calculates the number of blocks the TUP tokens of depositant will be locked in this contract. The depositant CAN NOT anticipate this time using TIME tokens
    /// @param depositant Address of the depositant of TUP tokens
    /// @param amountTup The amount of TUP tokens to be deposited
    function _adjustBlockToUnlock(address depositant, uint256 amountTup) private {
        uint256 previousBlockToUnlock = blockToUnlock[depositant];
        blockToUnlock[depositant] = block.number + calculateTimeToLock(amountTup);
        if (previousBlockToUnlock > 0) {
            if (blockToUnlock[depositant] > previousBlockToUnlock && previousBlockToUnlock > block.number) {
                blockToUnlock[depositant] = previousBlockToUnlock;
            }
        }
    }

    /// @notice Call the Worker contract to produce TIME and earn resources. It redirects the call to work() function of MinionCoordinator contract
    /// @dev Private function used to avoid onlyOncePerBlock modifier internally
    function _callToProduction() private returns (uint256) {
        uint256 time = minionCoordinator.work();
        _earn();
        return time.mulDiv(CALLER_FEE, 10_000);
    }

    /// @notice Performs routine to earn additional resources from Investor contract, TIME and TUP tokens
    /// @dev It takes advantage of some features of TIME and TUP tokens in order to earn native tokens of the underlying network
    function _earn() private {
        if (timeToken.withdrawableShareBalance(address(this)) > 0) {
            try timeToken.withdrawShare() { } catch { }
        }
        uint256 shares = tup.accountShareBalance(address(this));
        if (shares > 0) {
            _addTupToInvest(shares);
        }
        // try investor.harvest() { } catch { }
        _updateTupBalance();
    }

    /// @notice Returns the factor information about an informed amount of TUP tokens
    /// @dev It calculates the factor information from the amount of TUP and returns to the caller
    /// @param amountTup The amount of TUP tokens used to calculate factor
    /// @return factor The information about TUP total supply over the amount of TUP tokens informed
    function _getFactor(uint256 amountTup) private view returns (uint256) {
        return tup.totalSupply().mulDiv(10, amountTup + 1);
    }

    /// @notice Performs TUP token mint for a minter address given the amount of native and TIME tokens informed
    /// @dev Public and external functions can point to this private function since it can be reused for different purposes
    /// @param minter The address that will receive minted TUP tokens
    /// @param amountNative The amount of native tokens to be used in order to mint TUP tokens
    /// @param amountTime The amount of TIME tokens to be used in order to mint TUP tokens
    /// @param reinvestTup Checks whether the minted TUP will be reinvested in the contract
    function _mintTup(address minter, uint256 amountNative, uint256 amountTime, bool reinvestTup) private {
        require(
            tup.queryNativeFromTimeAmount(amountTime) <= amountNative,
            "Worker: the amount of TIME to be consumed must be less or equal than the native amount sent"
        );
        require(amountTime <= timeToken.balanceOf(address(this)), "Worker: it does not have enough amount of TIME to be consumed");
        require(amountNative <= address(this).balance, "Worker: contract does not have enough native amount to perform the operation");
        timeToken.approve(address(tup), amountTime);
        uint256 tupBalanceBefore = tup.balanceOf(address(this)) - tup.accountShareBalance(address(this));
        tup.mint{ value: amountNative }(amountTime);
        uint256 tupBalanceAfter = tup.balanceOf(address(this)) - tup.accountShareBalance(address(this));
        uint256 mintedTup = tupBalanceAfter - tupBalanceBefore;
        uint256 investorComission = mintedTup.mulDiv(INVESTMENT_FEE, 10_000);
        mintedTup -= investorComission;
        if (reinvestTup) {
            _registerDepositedTup(minter, mintedTup);
            _adjustBlockToUnlock(minter, depositedTup[minter]);
        } else {
            if (minter != address(this)) {
                tup.transfer(minter, mintedTup);
            }
        }
        if (investorComission > 0) {
            _addTupToInvest(investorComission);
        }
    }

    /// @notice Stores information about the amount of TUP tokens deposited from users
    /// @param from Address of the depositant
    /// @param amount Amount of TUP tokens deposited
    function _registerDepositedTup(address from, uint256 amount) private {
        depositedTup[from] += amount;
        totalDepositedTup += amount;
    }

    /// @notice Adjusts the amount of TUP in the contract according to the total amount tracked
    /// @dev It should consider the total amount from depositants plus the additional TUP received as profit from Investor contract. All exceeding amount should be transferred to the Investor
    function _updateTupBalance() private {
        uint256 currentTupBalance = tup.balanceOf(address(this));
        if (totalDepositedTup + totalAdditionalTupFromInvestor < currentTupBalance) {
            _addTupToInvest(currentTupBalance - (totalDepositedTup + totalAdditionalTupFromInvestor));
        }
    }

    /// @notice Withdraw some amount of deposited TUP tokens
    /// @dev We assume the temporal lock was previously checked before call this function
    /// @param to The receiver address of TUP tokens
    /// @param amount The amount of TUP tokens asked for withdrawn
    function _withdrawTup(address to, uint256 amount) private {
        require(
            tup.balanceOf(address(this)) >= amount && totalDepositedTup + totalAdditionalTupFromInvestor >= amount,
            "Worker: the contract does not have enough TUP to be withdrawn"
        );
        if (amount > totalAdditionalTupFromInvestor) {
            uint256 diff = amount - totalAdditionalTupFromInvestor;
            totalDepositedTup -= diff;
            totalAdditionalTupFromInvestor = 0;
        } else {
            totalAdditionalTupFromInvestor -= amount;
        }
        tup.transfer(to, amount);
    }

    /// @notice Calculates the amount of blocks needed to unlock TUP tokens of the depositants
    /// @dev It must consider the initial base timeframe, which can be altered by calling the updateBaseTimeFrame() function (admin only)
    /// @param amountTup The amount of TUP tokens deposited
    function calculateTimeToLock(uint256 amountTup) public view returns (uint256) {
        return _getFactor(amountTup).mulDiv(baseTimeFrame, 10);
    }

    /// @notice Externally calls the Worker contract and redirects this call to private function _callToProduction() in order to produce TIME and earn resources
    /// @dev Anyone can call this function and receive [(CALLER_FEE/10_000) * 100]% of the produced TIME (available in the contract only for TUP mint) and resources earned. _callerComission receives zero before transferring all the comission value
    /// @param callerAddress The address of the receiver of comission. It is used instead of msg.sender to avoid some types of MEV front running. If address zero is informed, all resources are sent to DEVELOPER_ADDRESS
    function callToProduction(address callerAddress) external nonReentrant onlyOncePerBlock {
        callerAddress = callerAddress == address(0) ? timeToken.DEVELOPER_ADDRESS() : callerAddress;
        uint256 timeEarned = _callToProduction();
        if (_callerComission > 0) {
            payable(callerAddress).transfer(_callerComission);
            _callerComission = 0;
        }
        // uint256 investorComission = timeEarned.mulDiv(INVESTMENT_FEE, 10_000);
        // timeEarned -= investorComission;
        // timeToken.transfer(address(investor), investorComission);
        availableTimeAsCaller[callerAddress] += timeEarned;
    }

    /// @notice Externally calls the Worker contract to create Minions on demand given some amount of native tokens paid/passed (msg.value parameter)
    /// @dev It performs some additional checks and redirects to the _createMinions() function
    /// @return numberOfMinionsCreated The number of active Minions created for TIME production
    function createMinions() external payable nonReentrant onlyOncePerBlock returns (uint256) {
        return minionCoordinator.createMinions{ value: msg.value }(msg.sender);
    }

    /// @notice Deposit TUP tokens into the contract to be able to receive some TIME tokens from Minions (proportionally) after production
    /// @dev Transfers the TUP tokens from the user wallet onto this contract, defines the time lock for them and register the depositant information. We assume the user has approved TUP token spend for this contract in advance
    /// @param amount The amount of TUP tokens to be deposited
    /// @return success Informs if the TUP tokens were transferred as expected
    function depositTup(uint256 amount) external nonReentrant onlyOncePerBlock returns (bool) {
        require(amount > 0, "Worker: TUP amount must be greater than zero");
        require(tup.allowance(msg.sender, address(this)) >= amount, "Worker: depositant must approve the TUP amount first");
        uint256 initialUserBalance = tup.balanceOf(msg.sender);
        tup.transferFrom(msg.sender, address(this), amount);
        _registerDepositedTup(msg.sender, amount);
        _adjustBlockToUnlock(msg.sender, depositedTup[msg.sender]);
        uint256 finalUserBalance = tup.balanceOf(msg.sender);
        try minionCoordinator.createMinionsForFree() {
            try minionCoordinator.work() { } catch { }
        } catch { }
        return (finalUserBalance < initialUserBalance);
    }

    /// @notice Call the Worker contract to earn resources, pay a given comission to the caller and reinvest comission in the contract
    /// @dev Call Minions for TIME production and this contract to earn resources from TIME and TUP tokens. It reinvests the earned comission with no cost for the caller
    function investWithNoCapital() external nonReentrant onlyOncePerBlock {
        availableTimeAsCaller[msg.sender] += _callToProduction();
        if (_callerComission > 0) {
            uint256 amountTimeNeeded = queryAvailableTimeForTupMint(_callerComission);
            uint256 amountNativeNeeded = tup.queryNativeFromTimeAmount(availableTimeAsCaller[msg.sender]);
            if (_callerComission >= amountNativeNeeded) {
                // mint TUP with _callerComission and availableTimeAsCaller[msg.sender] - nothing remains
                _mintTup(msg.sender, _callerComission, availableTimeAsCaller[msg.sender], true);
                _callerComission = 0;
                availableTimeAsCaller[msg.sender] = 0;
            } else if (availableTimeAsCaller[msg.sender] >= amountTimeNeeded) {
                // mint TUP with _callerComission and amountTimeNeeded - it remains some amount of availableTimeAsCaller[msg.sender]
                availableTimeAsCaller[msg.sender] -= amountTimeNeeded;
                _mintTup(msg.sender, _callerComission, amountTimeNeeded, true);
                _callerComission = 0;
            }
        }
    }

    /// @notice Performs TUP minting as depositant, using the TIME produced from Minions as part of collateral needed
    /// @dev It must check if the depositant who wants to mint TUP has enough TIME available to mint TUP giving the amount of native tokens passed to this function
    /// @param reinvestTup Checks whether the minted TUP will be reinvested in the contract
    function mintTupAsDepositant(bool reinvestTup) external payable nonReentrant onlyOncePerBlock {
        require(msg.value > 0, "Worker: please send some native tokens to mint TUP");
        require(
            depositedTup[msg.sender] > 0 || availableTimeAsCaller[msg.sender] > 0,
            "Worker: please refer the depositant should have some deposited TUP tokens in advance"
        );
        uint256 amountTimeAvailable = queryAvailableTimeForDepositant(msg.sender);
        uint256 amountNative = msg.value.mulDiv(10_000 - INVESTMENT_FEE, 10_000);
        uint256 amountTimeNeeded = queryAvailableTimeForTupMint(amountNative);
        require(amountTimeAvailable >= amountTimeNeeded, "Worker: depositant does not have enough TIME for mint TUP given the native amount provided");
        _addEarningsAndCalculateDividendPerToken(msg.value - amountNative);
        if (availableTimeAsCaller[msg.sender] < amountTimeNeeded) {
            availableTimeAsCaller[msg.sender] = 0;
        } else {
            availableTimeAsCaller[msg.sender] -= amountTimeNeeded;
        }
        _mintTup(msg.sender, amountNative, amountTimeNeeded, reinvestTup);
    }

    /// @notice Performs TUP minting as a third party involved. User also receives available TIME as reward for calling
    /// @dev It should calculate the correct amount to mint before internal calls
    /// @param minter The address that should receive TUP tokens minted
    /// @param reinvestTup Checks whether the minted TUP will be reinvested in the contract
    function mintTupAsThirdParty(address minter, bool reinvestTup) external payable nonReentrant onlyOncePerBlock {
        require(msg.value > 0, "Worker: please send some native tokens to mint TUP");
        uint256 amountNativeForTimeAllocation = msg.value.mulDiv(MAX_PERCENTAGE_ALLOCATION_OF_TIME, 10_000);
        uint256 amountNative = msg.value - amountNativeForTimeAllocation;
        uint256 amountTime = queryAvailableTimeForTupMint(amountNativeForTimeAllocation);
        // Adjusts the dividend per token
        _addEarningsAndCalculateDividendPerToken(amountNativeForTimeAllocation);
        _mintTup(minter, amountNative, amountTime, reinvestTup);
        if (availableTimeAsCaller[minter] > 0) {
            if (availableTimeAsCaller[minter] < amountTime) {
                if (availableTimeAsCaller[minter] <= timeToken.balanceOf(address(this))) {
                    timeToken.transfer(minter, availableTimeAsCaller[minter]);
                }
                availableTimeAsCaller[minter] = 0;
            } else {
                availableTimeAsCaller[minter] -= amountTime;
                if (amountTime <= timeToken.balanceOf(address(this))) {
                    timeToken.transfer(minter, amountTime);
                }
            }
        }
    }

    /// @notice Check the amount of additional TUP a depositant should receive. It is not dividend, but an additional amount the Investor contract earns from investments on third party contracts
    /// @dev It should calculate the proportion in terms of the amount of TUP deposited
    /// @param depositant The address of depositant
    /// @return additionalTupFromInvestor The amount of additional TUP a depositant should receive
    function queryAdditionalTupFromInvestor(address depositant) public view returns (uint256) {
        return depositedTup[depositant].mulDiv(totalAdditionalTupFromInvestor, totalDepositedTup);
    }

    /// @notice Query the amount of TIME available for a depositant address
    /// @dev It should reflect the amount of TIME a TUP depositant has after TIME being producted
    /// @param depositant The address of an user who has deposited and locked TUP in the contract
    /// @return amountTimeAvailable Amount of TIME available to depositant
    function queryAvailableTimeForDepositant(address depositant) public view returns (uint256) {
        return (timeToken.balanceOf(address(this)).mulDiv(depositedTup[depositant], totalDepositedTup + 1)).mulDiv(10_000 - CALLER_FEE, 10_000)
            + availableTimeAsCaller[depositant];
    }

    /// @notice Query the amount of TIME available to mint new TUP tokens given some amount of native tokens
    /// @dev It must consider the current price of TIME tokens
    /// @param amountNative The amount of native tokens an user wants to spend
    /// @return amountTimeAvailable The available amount of TIME tokens to be used
    function queryAvailableTimeForTupMint(uint256 amountNative) public view returns (uint256) {
        return amountNative.mulDiv(timeToken.swapPriceNative(amountNative), FACTOR);
    }

    /// @notice Query the amount of TUP a depositant should receive, including the additional received from Investor contract
    /// @dev It must consider the amount deposited from user plus the additional, proportionally shared among all users of the contract
    /// @param depositant The address of depositant
    /// @return availableTup The amount of TUP available to depositant
    function queryAvailableTup(address depositant) public view returns (uint256) {
        return depositedTup[depositant] + queryAdditionalTupFromInvestor(depositant);
    }

    /// @notice Queries the contract for the current earnings an user have
    /// @dev It should consider the developer team comission and fees to cover creation of new Minions
    /// @param depositant The address of an user who have investments in this contract
    /// @return currentEarnings The amount of native tokens the depositant should receive
    /// @return comission The comission that should be charged from earnings in terms of native tokens
    /// @return investorComission The comission dedicated to Investor contract. Earnings will be returned to TUP holders later
    /// @return minionCreationFee The amount of native tokens that should be used to cover expenses for creation of new Minions
    function queryCurrentEarnings(address depositant)
        public
        view
        returns (uint256 currentEarnings, uint256 comission, uint256 investorComission, uint256 minionCreationFee)
    {
        currentEarnings = depositedTup[depositant].mulDiv(_dividendPerToken - _consumedDividendPerToken[depositant], FACTOR);
        minionCreationFee = currentEarnings.mulDiv(MINION_CREATION_FEE, 10_000);
        comission = currentEarnings.mulDiv(INVESTMENT_FEE, 10_000);
        investorComission = comission;
        currentEarnings -= (comission + investorComission + minionCreationFee);
        return (currentEarnings, comission, investorComission, minionCreationFee);
    }

    /// @notice Queries the contract for the estimated amount needed to activate new Minions given an expected number of them
    /// @dev It should query the TIME token contract for the estimated fees to cover new activations
    /// @param numberOfMinions The number of new Minions an user wants to query
    /// @return amountNative The amount neeed to cover expenses, in terms of native tokens
    function queryFeeAmountToActivateMinions(uint256 numberOfMinions) public view returns (uint256) {
        return timeToken.fee().mulDiv(numberOfMinions, 1);
    }

    /// @notice Queries the minimum amount need to mint TUP tokens given the amount of ALL TIME tokens in the contract
    function queryMinNativeAmountToMintTup() public view returns (uint256) {
        return tup.queryNativeFromTimeAmount(timeToken.balanceOf(address(this)));
    }

    /// @notice Returns the estimated number of Minions should be created given an amount of native tokens informed
    /// @param amount The amount of native tokens that should be considered to create new Minions
    /// @return estimatedNumberOfMinions The estimated number of Minions
    function queryNumberOfMinionsToActivateFromAmount(uint256 amount) public view returns (uint256) {
        return amount.mulDiv(1, timeToken.fee() + 1);
    }

    /// @notice Queries the share of an depositant in terms of TUP tokens
    /// @param depositant The address of an depositant
    function queryShareFromDepositant(address depositant) public view returns (uint256) {
        return depositedTup[depositant].mulDiv(FACTOR, totalDepositedTup);
    }

    // /// @notice Receives an amount of TUP tokens back from Investor after earnings
    // /// @dev It must check if there is any amount to compensate, since TUP dividends earned by Worker are always sent to Investor in order to earn more yield
    // /// @param amountTup The amount of TUP tokens the Investor wants to send back
    // /// @return shouldCompensate Informs whether the Worker contract should send TUP tokens instead of receiveing them. It happens in cases where dividends to be received are greater than the amount coming from Investor
    // function receiveTupBack(uint256 amountTup) external onlyInvestor returns (bool shouldCompensate) {
    //     require(tup.allowance(address(investor), address(this)) >= amountTup, "Worker: the informed amount was not approved");
    //     uint256 compensation = tup.accountShareBalance(address(this));
    //     if (amountTup > compensation) {
    //         uint256 diff = amountTup - compensation;
    //         tup.transferFrom(address(investor), address(this), diff);
    //         totalAdditionalTupFromInvestor += diff;
    //     } else {
    //         shouldCompensate = true;
    //     }
    // }

    /// @notice Change the batch size value (maximum number of minions to be created in one transaction) of MinionCoordinator
    /// @dev It delegates the change to the contract, once the MinionCoordinator contract does not have admin functions
    /// @param newBatchSize The new value of the batch size
    function updateBatchSize(uint256 newBatchSize) external onlyOwner {
        minionCoordinator.updateBatchSize(newBatchSize);
    }

    /// @notice Adjusts the base time frame adopted to calculate time lock from deposits
    /// @dev Accessible only by admin/owner
    /// @param newBaseTimeFrame The new value that should be passed
    function updateBaseTimeFrame(uint256 newBaseTimeFrame) external onlyOwner {
        baseTimeFrame = newBaseTimeFrame;
    }

    // /// @notice Updates the address of the new investor contract to interact with the Worker
    // /// @dev The function asks for an instance, but the address is enough for an external caller. Admin only
    // /// @param newInvestor The instance/address of the Investor contract
    // function updateInvestor(Investor newInvestor) external onlyOwner {
    //     investor.updateInvestor();
    //     investor = newInvestor;
    //     _updateTupBalance();
    // }

    /// @notice Withdraws earnings of an user in terms of native tokens
    /// @dev It must check if the contract has enough balance to cover the amount asked. Also, it should calculate and charge all the needed comissions
    function withdrawEarnings() external nonReentrant onlyOncePerBlock {
        (uint256 amountToWithdraw, uint256 comission, uint256 investorComission, uint256 minionCreationFee) = queryCurrentEarnings(msg.sender);
        require(amountToWithdraw <= address(this).balance, "Worker: contract does not have enough native amount to perform the operation");
        _consumedDividendPerToken[msg.sender] = _dividendPerToken;
        minionCoordinator.addResourcesForMinionCreation{ value: minionCreationFee }();
        // investor.addNativeToInvest{ value: investorComission }();
        payable(timeToken.DEVELOPER_ADDRESS()).transfer(comission / 2);
        payable(DONATION_ADDRESS).transfer(comission / 2);
        payable(msg.sender).transfer(amountToWithdraw);
        try minionCoordinator.createMinionsForFree() {
            try minionCoordinator.work() { } catch { }
        } catch { }
    }

    /// @notice Performs withdrawing of the deposited TUP tokens
    /// @dev Checks the temporal lock to see if the depositant can withdraw the deposited TUP tokens
    function withdrawTup() external nonReentrant onlyOncePerBlock {
        require(block.number >= blockToUnlock[msg.sender], "Worker: depositant can not withdraw TUP at this moment");
        // It resets the block number required to unlock TUP tokens
        blockToUnlock[msg.sender] = 0;
        _withdrawTup(msg.sender, queryAvailableTup(msg.sender));
        try minionCoordinator.createMinionsForFree() {
            try minionCoordinator.work() { } catch { }
        } catch { }
    }
}
