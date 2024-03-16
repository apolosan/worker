// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBeefyVault, IERC20Upgradeable } from "@beefy/keepers/interfaces/IBeefyVault.sol";
import { IBeefyStrategy } from "@beefy/keepers/interfaces/IBeefyStrategy.sol";
import { IUniswapV2Factory } from "./IUniswapV2Factory.sol";
import { IUniswapV2Router02 } from "./IUniswapV2Router02.sol";
import { ISponsor, ITimeIsUp, Math, Ownable, Worker } from "./Worker.sol";
import { Minion, ITimeToken } from "./Minion.sol";

// TODO: contrato receberá dividendos em TUP do Worker. Decidir o que será feito desses dividendos e como implementar alguma estratégia p/ otimizar o uso
contract Investor is Minion, Ownable {

    using Math for uint256;

    enum AssetType {
        POOL,
        SINGLE
    }

    struct InvestorVault {
        IBeefyVault vaultInstance;
        AssetType vaultType;
    }

    ISponsor private _sponsor;
    ITimeIsUp private _tup;
    Worker private _worker;

    address public constant DONATION_ADDRESS = 0xbF616B8b8400373d53EC25bB21E2040adB9F927b;

    address public stakingContract;

    uint256 public constant PERCENTAGE_TO_PROFIT = 500;

    uint256 public amountTupFromWorker;
    uint256 public earnedFromInvestments;
    uint256 public earnedToInvest;
    uint256 public totalProfit;
    uint256 public totalReceivedToInvest;

    InvestorVault[] public vaults;

    mapping(address => uint256) public vaultBalance;

    constructor(
        address owner,
        Worker worker,
        ITimeToken timeToken,
        ITimeIsUp tup,
        ISponsor sponsor)
            Minion(address(this), timeToken)
            Ownable(owner) {
                _worker = worker;
                _tup = tup;
                _sponsor = sponsor;
    }

    receive() external payable {
        if (msg.value > 0) {
            earnedFromInvestments += msg.value;
            totalProfit += msg.value;
        }
    }

    fallback() external payable {
        require(msg.data.length == 0);
        if (msg.value > 0) {
            earnedFromInvestments += msg.value;
            totalProfit += msg.value;
        }
    }

    modifier onlyWorker() {
        require(msg.sender == address(_worker), "Investor: only Worker contract can perform this operation");
        _;
    }

    modifier generateTime() {
        _produceTime();
        _;
    }

    function _checkEarningsAndDistribute() private {
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].vaultInstance.balanceOf(address(this)) >=
                (vaultBalance[address(vaults[i].vaultInstance)] + vaultBalance[address(vaults[i].vaultInstance)].mulDiv(PERCENTAGE_TO_PROFIT, 10_000))) {
                    uint256 amountToWithdraw = vaults[i].vaultInstance.balanceOf(address(this)) - vaultBalance[address(vaults[i].vaultInstance)];
                    _withdrawFromVaultAndConvert(vaults[i].vaultInstance, amountToWithdraw);
            }
        }
        if (_timeToken.withdrawableShareBalance(address(this)) > 0)
            try _timeToken.withdrawShare() { } catch { }
        if (earnedFromInvestments > 0 && earnedFromInvestments <= (address(this).balance - earnedToInvest)) {
            if (address(_sponsor) != address(0)) {
                uint256 balanceInTime = _timeToken.balanceOf(address(this));
                _timeToken.approve(address(_sponsor), balanceInTime);
                _sponsor.extendParticipationPeriod(balanceInTime);
                if (_sponsor.prizeToClaim(address(this)) > 0)
                    _sponsor.claimPrize();
                if (earnedFromInvestments >= _sponsor.minAmountToEarnPoints()) {
                    try _sponsor.swap{value: earnedFromInvestments}(address(0), address(_tup), earnedFromInvestments) {
                        earnedFromInvestments = 0;
                    } catch { }
                }
            } else {
                try _tup.buy{value: earnedFromInvestments}() {
                    earnedFromInvestments = 0;
                } catch { }
            }
            _tup.approve(address(_worker), _tup.balanceOf(address(this)));
            if (_worker.receiveTupBack(_tup.balanceOf(address(this)))) {
                if (stakingContract != address(0)) {
                    _tup.transfer(stakingContract, _tup.balanceOf(address(this)));
                } else {
                    uint256 earnedBefore = earnedFromInvestments;
                    try _tup.sell(_tup.balanceOf(address(this))) {
                        uint256 diff = earnedFromInvestments - earnedBefore;
                        _timeToken.donateEth{value: diff}();
                        earnedFromInvestments -= diff;
                    } catch { }
                }
            }
        }
    }

    // Convert ETH to LP and deposit on Vault
    function _convertAndDepositOnVault(uint256 indexVault, uint256 amount) private returns (bool success) {
        require(amount <= earnedToInvest, "Investor: not enough balance to cover the informed amount");
        InvestorVault memory vault = vaults[indexVault];
        IBeefyVault vaultInstance = vault.vaultInstance;
        IBeefyStrategy strategy = IBeefyStrategy(vaultInstance.strategy());
        IUniswapV2Router02 router = IUniswapV2Router02(strategy.unirouter());
        address asset = address(vaultInstance.want());
        if (vault.vaultType == AssetType.POOL) {
            address token0 = strategy.lpToken0();
            address token1 = strategy.lpToken1();
            address[] memory path = new address[](2);
            path[0] = router.WETH();
            path[1] = token0;
            // adjusts the amount for each token pair to swap
            amount = amount / 2;
            // performs the swap
            try router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
                0,
                path,
                address(this),
                block.timestamp + 300
            ) { 
                success = true;
            } catch { }
            if (success) {
                path[1] = token1;
                try router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
                    0,
                    path,
                    address(this),
                    block.timestamp + 300
                ) { } catch {
                    success = false;
                }
            }
            // deposits on LP
            if (success) {
                try router.addLiquidity(
                    token0,
                    token1,
                    IERC20(token0).balanceOf(address(this)),
                    IERC20(token1).balanceOf(address(this)),
                    0,
                    0,
                    address(this),
                    block.timestamp + 300
                ) { } catch {
                    success = false;
                }
            }
        } else {
            address[] memory path = new address[](2);
            path[0] = router.WETH();
            path[1] = asset;
            try router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
                0,
                path,
                address(this),
                block.timestamp + 300
            ) {
                success = true;
            } catch { }
        }
        // deposits LP tokens on vault
        if (success) {
            earnedToInvest -= amount;
            IERC20(asset).approve(address(vault.vaultInstance), IERC20(asset).balanceOf(address(this)));
            try vaultInstance.depositAll() { } catch { }
            vaultBalance[address(vault.vaultInstance)] = vaultInstance.balanceOf(address(this));
        }
        return success;
    }

    function _performInvestment() private {
        uint256 currentLength = vaults.length;
        if (currentLength > 0 && earnedToInvest > 0 && earnedToInvest <= address(this).balance) {
            uint256 share = earnedToInvest / currentLength;
            for (uint256 i = 0; i < vaults.length; i++) {
                if (!_convertAndDepositOnVault(i, share)) {
                    currentLength--;
                    share = (currentLength > 0) ? share + (share / currentLength) : 0;
                }
            }
        }
    }

    function _withdrawFromAllVaults() private {
        for (uint256 i = 0; i < vaults.length; i++) {
            _withdrawFromVaultAndConvert(vaults[i].vaultInstance, vaultBalance[address(vaults[i].vaultInstance)]);
        }        
    }

    function _withdrawFromVaultAndConvert(IBeefyVault vaultInstance, uint256 amount) private returns (bool success) {
        if (amount > 0) {
            require(amount <= vaultInstance.balanceOf(address(this)), "Investor: not enough balance to withdraw from vault");
            vaultInstance.withdraw(amount);
            IUniswapV2Router02 router = IUniswapV2Router02(IBeefyStrategy(vaultInstance.strategy()).unirouter());
            try router.removeLiquidityETH(
                address(vaultInstance.want()),
                IERC20Upgradeable(vaultInstance.want()).balanceOf(address(this)),
                0,
                0,
                address(this),
                block.timestamp + 300
            ) { 
                success = true;
            } catch { }
        }
        return success;
    }

    function addNativeToInvest() external payable onlyWorker generateTime returns (bool success) {
        if (msg.value > 0) {
            totalReceivedToInvest += msg.value;
            earnedToInvest += msg.value;
            success = true;
        }
        return success;
    }    

    function addTupToInvest(uint256 amountTup) external onlyWorker generateTime {
        require(_tup.allowance(address(_worker), address(this)) >= amountTup, "Investor: the informed amount was not approved");
        _tup.transferFrom(address(_worker), address(this), amountTup);
        amountTupFromWorker += amountTup;
    }

    function addVault(address vaultAddress, AssetType vaultType) external onlyOwner {
        vaults.push(InvestorVault(IBeefyVault(vaultAddress), vaultType));
    }

    // TODO: terminar essa função
    function harvest() external onlyWorker generateTime {
        _checkEarningsAndDistribute();
    }

    function queryCurrentROI() public view returns (uint256) {
        return totalProfit.mulDiv(_worker.FACTOR(), totalReceivedToInvest);
    }

    function removeVault(address vaultAddress) external onlyOwner {
        if (vaultAddress != address(0)) {
            bool found;
            for (uint256 i = 0; i < vaults.length; i++) {
                if (vaultAddress == address(vaults[i].vaultInstance)) {
                    for (uint256 j = i; j < vaults.length - 1; j++) {
                        vaults[j] = vaults[j + 1];
                    }
                    found = true;
                    break;
                }
            }
            if (found) {
                vaults.pop();
                _withdrawFromVaultAndConvert(IBeefyVault(vaultAddress), IBeefyVault(vaultAddress).balanceOf(address(this)));
            }
        }
    }    

    // TODO: ajustar essa função p/ retirar fundos de outros contratos, se houver
    function updateInvestor() external onlyWorker generateTime {
        _tup.transfer(address(_worker), _tup.balanceOf(address(this)));
        _timeToken.transfer(address(_worker), _timeToken.balanceOf(address(this)));
        earnedFromInvestments = 0;
        payable(address(_worker)).transfer(address(this).balance);
    }

    function updateStakingContract(address newStakingContract) external onlyOwner {
        stakingContract = newStakingContract;
    }
}