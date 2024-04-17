// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IEmployer } from "./IEmployer.sol";
import { InvestmentCoordinator } from "./InvestmentCoordinator.sol";
import { ITimeIsUp } from "./ITimeIsUp.sol";
import { ITimeToken } from "./ITimeToken.sol";
import { IWorker, MinionCoordinator } from "./MinionCoordinator.sol";

contract WorkerVault is ERC4626, Ownable, IWorker {
    using Math for uint256;

    bool private _isOperationLocked;

    InvestmentCoordinator public investmentCoordinator;
    ITimeToken public timeToken;
    MinionCoordinator public minionCoordinator;

    address public constant DONATION_ADDRESS = 0xbF616B8b8400373d53EC25bB21E2040adB9F927b;

    uint256 public constant DONATION_FEE = 25;
    uint256 public constant CALLER_FEE = 50;
    uint256 public constant FACTOR = 10 ** 18;
    uint256 public constant INVESTMENT_FEE = 50;
    uint256 public constant MAX_PERCENTAGE_ALLOCATION_OF_TIME = 4_900;
    uint256 public constant MINION_CREATION_FEE = 75;

    uint256 private _callerComission;
    uint256 private _donations;
    uint256 private _minionCreation;

    uint256 public baseTimeFrame;
    uint256 public earnedAmount;

    mapping(address => uint256) private _currentBlock;

    mapping(address => uint256) public availableTimeAsCaller;
    mapping(address => uint256) public blockToUnlock;

    // TODO: write documentation for each error code and fix the current documentation
    error DepositEqualsToZero();
    error NotAllowed(string message);
    error NotHaveEnoughBalance(uint256 amountAsked, uint256 amountAvailable);
    error NotHaveEnoughTime(uint256 timeAsked, uint256 balanceInTime);
    error NoTupMinted();
    error OperationLocked(address sender, uint256 blockNumber);
    error TimeValueConsumedGreaterThanNative(uint256 timeValue, uint256 native);
    error WithdrawLocked(uint256 currentBlock, uint256 blockToWithdraw);

    // POST-CONDITIONS:
    // IMPORTANT (at deployment):
    //      * deposit a minimum amount of TUP in the contract to avoid frontrunning "donation" attack
    //      * "burn" the share of the minimum amount deposited
    constructor(address _asset, address _timeTokenAddress, address _employerAddress, address _owner)
        ERC20("Worker Vault", "vWORK")
        ERC4626(ERC20(_asset))
        Ownable(_owner)
    {
        timeToken = ITimeToken(payable(_timeTokenAddress));
        IEmployer employer = IEmployer(payable(_employerAddress));
        minionCoordinator = new MinionCoordinator(this);
        baseTimeFrame = employer.ONE_YEAR().mulDiv(1, employer.D().mulDiv(365, 1));
        investmentCoordinator = new InvestmentCoordinator(address(this), _owner);
    }

    receive() external payable {
        if (msg.value > 0) {
            _splitEarnings(msg.value);
        }
    }

    fallback() external payable {
        require(msg.data.length == 0);
        if (msg.value > 0) {
            _splitEarnings(msg.value);
        }
    }

    /// @notice Modifier used to avoid reentrancy attacks
    modifier nonReentrant() {
        if (_isOperationLocked) {
            revert OperationLocked(_msgSender(), block.number);
        }
        _isOperationLocked = true;
        _;
        _isOperationLocked = false;
    }

    /// @notice Modifier to make a function runs only once per block (also avoids reentrancy, but in a different way)
    modifier onlyOncePerBlock() {
        if (block.number == _currentBlock[tx.origin]) {
            revert OperationLocked(tx.origin, block.number);
        }
        _currentBlock[tx.origin] = block.number;
        _;
    }

    function _addTimeToInvest(uint256 amountTime) private {
        if (amountTime > 0) {
            try timeToken.transfer(address(investmentCoordinator), amountTime) {
                try investmentCoordinator.depositAssetOnVault(address(timeToken)) { } catch { }
            } catch { }
        }
    }

    /// @notice Dedicate some TUP tokens for investments which should add value to the whole platform and will be distributed to users
    /// @dev Approve and transfer TUP to Investor contract
    /// @param amountTup The amount of TUP tokens to be transferred to Investor
    function _addTupToInvest(uint256 amountTup) private {
        if (amountTup > 0) {
            try ITimeIsUp(asset()).transfer(address(investmentCoordinator), amountTup) {
                try investmentCoordinator.depositAssetOnVault(asset()) { } catch { } 
            } catch { }
        }
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

    function _afterDeposit(uint256 assets, uint256 shares) private {
        assets = assets == 0 ? convertToAssets(shares) : assets;
        _adjustBlockToUnlock(_msgSender(), assets);
        _earn();
        if (_minionCreation > 0) {
            minionCoordinator.addResourcesForMinionCreation{ value: _minionCreation }();
            _minionCreation = 0;
        }
        if (_donations > 0) {
            payable(DONATION_ADDRESS).call{ value: _donations }("");
            _donations = 0;
        }
        if (minionCoordinator.dedicatedAmount() > 0) {
            try minionCoordinator.createMinionsForFree() { } catch { }
        }
        _callToProduction(false);
        _addTupToInvest(assets.mulDiv(INVESTMENT_FEE, 10_000));
    }

    function _afterWithdraw(uint256 assets, uint256 shares) private {
        _earn();
        if (_minionCreation > 0) {
            minionCoordinator.addResourcesForMinionCreation{ value: _minionCreation }();
            _minionCreation = 0;
        }
        if (_donations > 0) {
            payable(DONATION_ADDRESS).call{ value: _donations }("");
            _donations = 0;
        }
        if (minionCoordinator.dedicatedAmount() > 0) {
            try minionCoordinator.createMinionsForFree() { } catch { }
        }
        _callToProduction(false);
    }

    function _beforeDeposit(uint256 assets, uint256 shares) private {
        assets = assets == 0 ? convertToAssets(shares) : assets;
        if (assets == 0) {
            revert DepositEqualsToZero();
        }
    }

    function _beforeWithdraw(uint256 assets, uint256 shares) private {
        if (block.number < blockToUnlock[_msgSender()]) {
            revert WithdrawLocked(block.number, blockToUnlock[_msgSender()]);
        }
    }

    /// @notice Call the Worker contract to produce TIME and earn resources. It redirects the call to work() function of MinionCoordinator contract
    /// @dev Private function used to avoid onlyOncePerBlock modifier internally
    /// @param chargeFeeForCaller Informs whether the function should charge some fee for the caller
    function _callToProduction(bool chargeFeeForCaller) private returns (uint256 production) {
        if (chargeFeeForCaller) {
            production = minionCoordinator.work().mulDiv(CALLER_FEE, 10_000);
        } else {
            try minionCoordinator.work() returns (uint256 amount) {
                production = amount;
            } catch {
                production = 0;
            }
        }
        if (production > 0) {
            _addTimeToInvest(timeToken.balanceOf(address(this)).mulDiv(INVESTMENT_FEE, 10_000));
        }
    }

    /// @notice Performs routine to earn additional resources from Investor contract, TIME and TUP tokens
    /// @dev It takes advantage of some features of TIME and TUP tokens in order to earn native tokens of the underlying network
    function _earn() private {
        if (timeToken.withdrawableShareBalance(address(this)) > 0) {
            try timeToken.withdrawShare() { } catch { }
        }
        uint256 tupDividends = ITimeIsUp(asset()).accountShareBalance(address(this));
        _addTupToInvest(tupDividends);
    }

    /// @notice Returns the factor information about an informed amount of TUP tokens
    /// @dev It calculates the factor information from the amount of TUP and returns to the caller
    /// @param amountTup The amount of TUP tokens used to calculate factor
    /// @return factor The information about TUP total supply over the amount of TUP tokens informed
    function _getFactor(uint256 amountTup) private view returns (uint256) {
        return ITimeIsUp(asset()).totalSupply().mulDiv(10, amountTup + 1);
    }

    /// @notice Performs TUP token mint for a minter address given the amount of native and TIME tokens informed
    /// @dev Public and external functions can point to this private function since it can be reused for different purposes
    /// @param minter The address that will receive minted TUP tokens
    /// @param amountNative The amount of native tokens to be used in order to mint TUP tokens
    /// @param amountTime The amount of TIME tokens to be used in order to mint TUP tokens
    /// @param reinvestTup Checks whether the minted TUP will be reinvested in the contract
    function _mintTup(address minter, uint256 amountNative, uint256 amountTime, bool reinvestTup) private {
        if (ITimeIsUp(asset()).queryNativeFromTimeAmount(amountTime) > amountNative) {
            revert TimeValueConsumedGreaterThanNative(ITimeIsUp(asset()).queryNativeFromTimeAmount(amountTime), amountNative);
        }
        if (amountTime > timeToken.balanceOf(address(this))) {
            revert NotHaveEnoughTime(amountTime, timeToken.balanceOf(address(this)));
        }
        if (amountNative > address(this).balance) {
            revert NotHaveEnoughBalance(amountNative, address(this).balance);
        }
        timeToken.approve(asset(), amountTime);
        uint256 tupBalanceBefore = ITimeIsUp(asset()).balanceOf(address(this)) - ITimeIsUp(asset()).accountShareBalance(address(this));
        ITimeIsUp(asset()).mint{ value: amountNative }(amountTime);
        uint256 tupBalanceAfter = ITimeIsUp(asset()).balanceOf(address(this)) - ITimeIsUp(asset()).accountShareBalance(address(this));
        uint256 mintedTup = tupBalanceAfter - tupBalanceBefore;
        if (mintedTup == 0) {
            revert NoTupMinted();
        }
        if (reinvestTup) {
            uint256 shares = convertToShares(mintedTup);
            _mint(minter, shares);
            _adjustBlockToUnlock(minter, mintedTup);
            emit Deposit(minter, minter, mintedTup, shares);
        } else {
            if (minter != address(this)) {
                ITimeIsUp(asset()).transfer(minter, mintedTup);
            }
        }
    }

    function _remainingBalance() private view returns (uint256) {
        uint256 total = earnedAmount + _callerComission + _donations + _minionCreation;
        if (address(this).balance > total) {
            return address(this).balance - total;
        } else {
            return 0;
        }
    }

    function _sellComissionTup(uint256 amount) private {
        try ITimeIsUp(asset()).sell(amount) { } catch { }
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        _adjustBlockToUnlock(to, convertToAssets(value));
        if (balanceOf(from) == 0) {
            blockToUnlock[from] = 0;
        }
    }

    /// @notice Add the earned amount from this contract at the moment into the total earned amount (historic)
    /// @param earned The amount earned from this contract at the moment
    function _splitEarnings(uint256 earned) private returns (uint256) {
        uint256 currentCallerComission = earned.mulDiv(CALLER_FEE, 10_000);
        uint256 currentDonation = earned.mulDiv(DONATION_FEE, 10_000);
        uint256 currentMinionCreationFee = earned.mulDiv(MINION_CREATION_FEE, 10_000);
        _donations += currentDonation;
        _minionCreation += currentMinionCreationFee;
        _callerComission += currentCallerComission;
        earned -= (currentDonation + currentMinionCreationFee + currentCallerComission);
        earnedAmount += earned;
        return earned;
    }

    /// @notice Calculates the amount of blocks needed to unlock TUP tokens of the depositants
    /// @dev It must consider the initial base timeframe, which can be altered by calling the updateBaseTimeFrame() function (admin only)
    /// @param amountTup The amount of TUP tokens deposited
    function calculateTimeToLock(uint256 amountTup) public view returns (uint256) {
        return _getFactor(amountTup).mulDiv(baseTimeFrame, 10);
    }

    /// @notice Externally calls the Worker contract and redirects this call to private function _callToProduction(bool chargeFeeForCaller) in order to produce TIME and earn resources
    /// @dev Anyone can call this function and receive [(CALLER_FEE/10_000) * 100]% of the produced TIME (available in the contract only for TUP mint) and resources earned. _callerComission receives zero before transferring all the comission value
    /// @param callerAddress The address of the receiver of comission. It is used instead of msg.sender to avoid some types of MEV front running. If address zero is informed, all resources are sent to DEVELOPER_ADDRESS
    function callToProduction(address callerAddress) external nonReentrant onlyOncePerBlock {
        callerAddress = callerAddress == address(0) ? timeToken.DEVELOPER_ADDRESS() : callerAddress;
        availableTimeAsCaller[callerAddress] += _callToProduction(true);
        _earn();
        if (_callerComission > 0) {
            _mintTup(callerAddress, _callerComission, 0, false);
            _callerComission = 0;
        }
    }

    /// @notice Externally calls the Worker contract to create Minions on demand given some amount of native tokens paid/passed (msg.value parameter)
    /// @dev It performs some additional checks and redirects to the _createMinions() function
    /// @return numberOfMinionsCreated The number of active Minions created for TIME production
    function createMinions() external payable nonReentrant onlyOncePerBlock returns (uint256) {
        return minionCoordinator.createMinions{ value: msg.value }(_msgSender());
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant onlyOncePerBlock returns (uint256 shares) {
        _beforeDeposit(assets, shares);
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        _afterDeposit(assets, shares);
    }

    /// @notice Call the Worker contract to earn resources, pay a given comission to the caller and reinvest comission in the contract
    /// @dev Call Minions for TIME production and this contract to earn resources from TIME and TUP tokens. It reinvests the earned comission with no cost for the caller
    function investWithNoCapital() external nonReentrant onlyOncePerBlock {
        availableTimeAsCaller[_msgSender()] += _callToProduction(true);
        _earn();
        if (_callerComission > 0) {
            uint256 amountTimeNeeded = queryAvailableTimeForTupMint(_callerComission);
            uint256 amountNativeNeeded = ITimeIsUp(asset()).queryNativeFromTimeAmount(availableTimeAsCaller[_msgSender()]);
            if (_callerComission >= amountNativeNeeded) {
                // mint and reinvest TUP with _callerComission and availableTimeAsCaller[_msgSender()] - nothing remains
                _mintTup(_msgSender(), _callerComission, availableTimeAsCaller[_msgSender()], true);
                _callerComission = 0;
                availableTimeAsCaller[_msgSender()] = 0;
            } else if (availableTimeAsCaller[_msgSender()] >= amountTimeNeeded) {
                // mint and reinvest TUP with _callerComission and amountTimeNeeded - it remains some amount of availableTimeAsCaller[_msgSender()]
                availableTimeAsCaller[_msgSender()] -= amountTimeNeeded;
                _mintTup(_msgSender(), _callerComission, amountTimeNeeded, true);
                _callerComission = 0;
            }
        }
    }

    function mint(uint256 shares, address receiver) public override nonReentrant onlyOncePerBlock returns (uint256 assets) {
        _beforeDeposit(assets, shares);
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }
        assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);
        _afterDeposit(assets, shares);
    }

    /// @notice Performs TUP minting as depositant, using the TIME produced from Minions as part of collateral needed
    /// @dev It must check if the depositant who wants to mint TUP has enough TIME available to mint TUP giving the amount of native tokens passed to this function
    /// @param reinvestTup Checks whether the minted TUP will be reinvested in the contract
    function mintTupAsDepositant(bool reinvestTup) external payable nonReentrant onlyOncePerBlock {
        if (msg.value == 0) {
            revert DepositEqualsToZero();
        }
        if (convertToAssets(balanceOf(_msgSender())) == 0) {
            revert NotAllowed("Worker: please refer the depositant should have some deposited TUP tokens in advance");
        }
        uint256 amountNative = _splitEarnings(msg.value);
        uint256 amountTimeAvailable = queryAvailableTimeForDepositant(_msgSender());
        uint256 amountTimeNeeded = queryAvailableTimeForTupMint(amountNative);
        if (amountTimeAvailable < amountTimeNeeded) {
            revert NotHaveEnoughTime(amountTimeNeeded, amountTimeAvailable);
        }
        if (availableTimeAsCaller[_msgSender()] < amountTimeNeeded) {
            availableTimeAsCaller[_msgSender()] = 0;
        } else {
            availableTimeAsCaller[_msgSender()] -= amountTimeNeeded;
        }
        _mintTup(_msgSender(), amountNative, amountTimeNeeded, reinvestTup);
        earnedAmount -= amountNative;
        if (_remainingBalance() > 0) {
            _mintTup(address(this), _remainingBalance(), 0, false);
            earnedAmount = 0;
        }
    }

    /// @notice Performs TUP minting as a third party involved. User also receives available TIME as reward for calling
    /// @dev It should calculate the correct amount to mint before internal calls
    /// @param minter The address that should receive TUP tokens minted
    /// @param reinvestTup Checks whether the minted TUP will be reinvested in the contract
    function mintTupAsThirdParty(address minter, bool reinvestTup) external payable nonReentrant onlyOncePerBlock {
        if (msg.value == 0) {
            revert DepositEqualsToZero();
        }
        uint256 amountNativeForTimeAllocation = msg.value.mulDiv(MAX_PERCENTAGE_ALLOCATION_OF_TIME, 10_000);
        uint256 amountTime = queryAvailableTimeForTupMint(amountNativeForTimeAllocation);
        uint256 amountNative = _splitEarnings(msg.value - amountNativeForTimeAllocation);
        _mintTup(minter, amountNative, amountTime, reinvestTup);
        earnedAmount -= amountNative;
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
        if (_remainingBalance() > 0) {
            _mintTup(address(this), _remainingBalance(), 0, false);
            earnedAmount = 0;
        }
    }

    /// @notice Query the amount of TIME available for a depositant address
    /// @dev It should reflect the amount of TIME a TUP depositant has after TIME being producted
    /// @param depositant The address of an user who has deposited and locked TUP in the contract
    /// @return amountTimeAvailable Amount of TIME available to depositant
    function queryAvailableTimeForDepositant(address depositant) public view returns (uint256) {
        return (timeToken.balanceOf(address(this)).mulDiv(convertToAssets(balanceOf(depositant)), totalAssets() + 1)).mulDiv(
            10_000 - (CALLER_FEE + INVESTMENT_FEE), 10_000
        ) + availableTimeAsCaller[depositant];
    }

    /// @notice Query the amount of TIME available to mint new TUP tokens given some amount of native tokens
    /// @dev It must consider the current price of TIME tokens
    /// @param amountNative The amount of native tokens an user wants to spend
    /// @return amountTimeAvailable The available amount of TIME tokens to be used
    function queryAvailableTimeForTupMint(uint256 amountNative) public view returns (uint256) {
        return amountNative.mulDiv(timeToken.swapPriceNative(amountNative), FACTOR);
    }

    /// @notice Queries the contract for the estimated amount needed to activate new Minions given an expected number of them
    /// @dev It should query the TIME token contract for the estimated fees to cover new activations
    /// @param numberOfMinions The number of new Minions an user wants to query
    /// @return amountNative The amount neeed to cover expenses, in terms of native tokens
    function queryFeeAmountToActivateMinions(uint256 numberOfMinions) public view returns (uint256) {
        return timeToken.fee().mulDiv(numberOfMinions, 1);
    }

    function queryInvestedAmountForAsset(address _asset) external view returns (uint256) {
        return investmentCoordinator.queryTotalInvestedAmountForAsset(_asset);
    }

    /// @notice Queries the minimum amount need to mint TUP tokens given the amount of ALL TIME tokens in the contract
    function queryMinNativeAmountToMintTup() public view returns (uint256) {
        return ITimeIsUp(asset()).queryNativeFromTimeAmount(timeToken.balanceOf(address(this)));
    }

    /// @notice Returns the estimated number of Minions should be created given an amount of native tokens informed
    /// @param amount The amount of native tokens that should be considered to create new Minions
    /// @return estimatedNumberOfMinions The estimated number of Minions
    function queryNumberOfMinionsToActivateFromAmount(uint256 amount) public view returns (uint256) {
        return amount.mulDiv(1, timeToken.fee() + 1);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant onlyOncePerBlock returns (uint256 assets) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }
        assets = previewRedeem(shares);
        _beforeWithdraw(assets, shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        _afterWithdraw(assets, shares);
    }

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

    /// @notice Updates the MinionCoordinator contract to interact with the Worker
    /// @dev Also asks for an instance, but the address of the new contract is enough. Admin only
    /// @param newMinionCoordinator The instance of the new contract
    function updateMinionCoordinator(MinionCoordinator newMinionCoordinator) external onlyOwner {
        newMinionCoordinator.transferMinionsBetweenCoordinators(minionCoordinator);
        minionCoordinator.updateCoordinator(newMinionCoordinator);
        minionCoordinator = newMinionCoordinator;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant onlyOncePerBlock returns (uint256 shares) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }
        shares = previewWithdraw(assets);
        _beforeWithdraw(assets, shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        _afterWithdraw(assets, shares);
    }
}
