// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { console } from "forge-std/console.sol";
import { stdStorage, StdStorage, StdCheats, Test } from "forge-std/Test.sol";
import { WorkerVault, IEmployer, InvestmentCoordinator, ITimeIsUp, ITimeToken, MinionCoordinator } from "../src/WorkerVault.sol";
import { TimeTokenVault } from "../src/TimeTokenVault.sol";
import { TupBtcVault } from "../src/TupBtcVault.sol";

import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { FixedPoint96 } from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";

import { ISponsor } from "../src/ISponsor.sol";
import { IUniswapV2Router02 } from "../src/IUniswapV2Router02.sol";
import { IWETH } from "../src/IWETH.sol";

contract WorkerVaultTest2 is Test {
    // POLYGON MAINNET
    uint256 public blockNumber = block.number;

    uint24[] private UNISWAP_FEES = [500, 3_000, 10_000, 100];

    address public constant EMPLOYER_ADDRESS = 0x496ebDb161a87FeDa58f7EFFf4b2B94E10a1b655;
    address public constant ORACLE_ADDRESS = 0xc907E116054Ad103354f2D350FD2514433D57F6f;
    address public constant TIME_EXCHANGE_ADDRESS = 0xb46F8A90492D0d03b8c3ab112179c56F89A6f3e0;
    address public constant TIME_TOKEN_ADDRESS = 0x1666Cf136d89Ba9071C476eaF23035Bccd7f3A36;
    address public constant TIME_IS_UP_ADDRESS = 0x57685Ddbc1498f7873963CEE5C186C7D95D91688;
    address public constant ROUTER_V2_ADDRESS = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address public constant ROUTER_V3_ADDRESS = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant SPONSOR_ADDRESS = 0x4925784808cdcb23DA64BCbb7B5827ebc344B168;
    address public constant WBTC_ADDRESS = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    address public wETH;

    WorkerVault workerVault;
    ITimeToken timeToken;
    ITimeIsUp tup;
    IEmployer employer;
    IUniswapV2Router02 public routerV2;
    ISwapRouter public routerV3;
    TupBtcVault tupBtcVault;
    TimeTokenVault timeTokenVault;

    receive() external payable { }

    fallback() external payable { }

    function setUp() public {
        vm.label(EMPLOYER_ADDRESS, "Employer");
        vm.label(TIME_EXCHANGE_ADDRESS, "TimeExchange");
        vm.label(TIME_TOKEN_ADDRESS, "TIME");
        vm.label(TIME_IS_UP_ADDRESS, "TUP");
        vm.label(SPONSOR_ADDRESS, "Sponsor");
        vm.label(ROUTER_V2_ADDRESS, "RouterV2");
        vm.label(ROUTER_V3_ADDRESS, "RouterV3");

        timeToken = ITimeToken(payable(TIME_TOKEN_ADDRESS));
        tup = ITimeIsUp(payable(TIME_IS_UP_ADDRESS));
        employer = IEmployer(payable(EMPLOYER_ADDRESS));
        routerV2 = IUniswapV2Router02(payable(ROUTER_V2_ADDRESS));
        routerV3 = ISwapRouter(payable(ROUTER_V3_ADDRESS));

        wETH = routerV2.WETH();

        uint256 amount = 1 ether;
        vm.deal(address(this), (timeToken.fee() + amount) * 100);
        workerVault = new WorkerVault(TIME_IS_UP_ADDRESS, TIME_TOKEN_ADDRESS, EMPLOYER_ADDRESS, address(this));
        tup.buy{ value: amount }();
        tup.approve(address(workerVault), tup.balanceOf(address(this)));
        workerVault.mint(tup.balanceOf(address(this)), address(this));
        workerVault.transfer(address(0xdead), workerVault.balanceOf(address(this)));
        vm.label(address(workerVault), "vWORK");
        tupBtcVault = new TupBtcVault(
            TIME_IS_UP_ADDRESS, WBTC_ADDRESS, TIME_TOKEN_ADDRESS, SPONSOR_ADDRESS, ROUTER_V2_ADDRESS, ROUTER_V3_ADDRESS, address(this)
        );
        timeTokenVault = new TimeTokenVault(TIME_TOKEN_ADDRESS, address(this));
        InvestmentCoordinator(workerVault.investmentCoordinator()).addVault(address(timeTokenVault));
        InvestmentCoordinator(workerVault.investmentCoordinator()).addVault(address(tupBtcVault));
        vm.label(address(workerVault.investmentCoordinator()), "InvestmentCoordinator");
    }

    function _depositTupAndLock(uint256 amount) private {
        vm.assume(amount > 0.01 ether && amount <= 100_000 ether);
        vm.deal(address(this), amount);

        vm.roll(++blockNumber);
        tup.buy{ value: amount }();
        uint256 amountToDeposit = tup.balanceOf(address(this));
        vm.roll(++blockNumber);
        tup.approve(address(workerVault), amountToDeposit);
        vm.roll(++blockNumber);
        workerVault.deposit(amountToDeposit, address(this));

        emit log_named_uint("TUP Total Supply                   ", tup.totalSupply());
        emit log_named_uint("TUP Balance on WorkerVault         ", tup.balanceOf(address(workerVault)));
        emit log_named_uint("Total Shares               (vWORK) ", workerVault.totalSupply());
        emit log_named_uint("Deposited Shares           (vWORK) ", workerVault.balanceOf(address(this)));
        emit log_named_uint("Deposited Assets           (TUP)   ", amountToDeposit);
        emit log_named_uint("Deposited Assets on Vault  (TUP)   ", workerVault.previewRedeem(workerVault.balanceOf(address(this))));
        emit log_named_uint("Current Block                      ", block.number);
        emit log_named_uint("Block to Unlock                    ", workerVault.blockToUnlock(address(this)));
        emit log_named_uint("Locked Time                        ", workerVault.blockToUnlock(address(this)) - block.number);

        assertGt(workerVault.balanceOf(address(this)), 0);
        assertGt(workerVault.blockToUnlock(address(this)), 0);
        assertEq(workerVault.balanceOf(address(1)), 0);
        assertEq(workerVault.blockToUnlock(address(1)), 0);
    }

    function _exchangeFromEthToBtc(uint256 amount) private returns (bool success) {
        address[] memory path_ETH_BTC = new address[](2);
        path_ETH_BTC[0] = wETH;
        path_ETH_BTC[1] = WBTC_ADDRESS;
        vm.deal(address(this), amount * 100);
        if (IERC20(wETH).balanceOf(address(this)) > 0) {
            IWETH(wETH).withdraw(IERC20(wETH).balanceOf(address(this)));
        }
        if (amount > 0) {
            for (uint256 i = 0; i < UNISWAP_FEES.length; i++) {
                bytes memory path = abi.encodePacked(wETH, UNISWAP_FEES[i], WBTC_ADDRESS);
                ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams(path, address(this), block.timestamp + 300, amount, 0);
                vm.roll(++blockNumber);
                try routerV3.exactInput{ value: amount }(params) {
                    success = true;
                    break;
                } catch {
                    continue;
                }
            }
        }
    }

    function _testTupForwardingToInvestorAndAllocation(uint256 amount) private {
        _depositTupAndLock(amount);
        vm.roll(++blockNumber);
        vm.deal(address(this), amount * 100);
        payable(address(workerVault)).call{ value: amount * 10 }("");
        uint256 investorBalanceInTupBefore = tup.balanceOf(address(workerVault.investmentCoordinator()));
        tup.splitSharesWithReward();
        vm.roll(++blockNumber);
        tup.receiveProfit{ value: amount * 10 }();
        vm.roll(++blockNumber);
        workerVault.callToProduction(address(this));
        uint256 investorBalanceInTupAfter = tup.balanceOf(address(workerVault.investmentCoordinator()));
        // emit log_named_uint("Investor Balance in TUP Before     ", investorBalanceInTupBefore);
        emit log_named_uint("Invested Amount for TUP            ", workerVault.queryInvestedAmountForAsset(TIME_IS_UP_ADDRESS));
        assertGt(workerVault.queryInvestedAmountForAsset(TIME_IS_UP_ADDRESS), 0);
    }

    // forge test --match-contract WorkerVaultTest2 --match-test testTupForwardingToInvestor --rpc-url "polygon" --block-gas-limit 5000000000000000000 -vvv
    function testTupForwardingToInvestor() public {
        uint256 amount = 1 ether;
        _testTupForwardingToInvestorAndAllocation(amount);
    }

    function testFuzzTupForwardingToInvestor(uint256 amount) public {
        vm.assume(amount >= 0.01 ether && amount < 10 ether);
        _testTupForwardingToInvestorAndAllocation(amount);
    }

    // forge test --match-contract WorkerVaultTest2 --match-test testProfitEarning --rpc-url "polygon" --block-gas-limit 5000000000000000000 -vvv
    function testProfitEarning() public {
        uint256 amount = 500 ether;
        _depositTupAndLock(amount);
        _exchangeFromEthToBtc(100_000 ether);
        vm.roll(++blockNumber);
        uint256 balanceInTupBefore = tup.balanceOf(address(workerVault));
        InvestmentCoordinator(workerVault.investmentCoordinator()).checkProfitAndWithdraw();
        uint256 balanceInTupAfter = tup.balanceOf(address(workerVault));
        emit log_named_uint("Balance in TUP Before Profit       ", balanceInTupBefore);
        emit log_named_uint("Balance in TUP Ater Profit         ", balanceInTupAfter);
        assertGt(balanceInTupAfter, balanceInTupBefore);
    }

    // forge test --match-contract WorkerVaultTest2 --match-test testVaultRemoval --rpc-url "polygon" --block-gas-limit 5000000000000000000 -vvv
    function testVaultRemoval() public {
        uint256 amount = 50 ether;
        _depositTupAndLock(amount);
        uint256 balanceInTupBefore = tup.balanceOf(address(workerVault.investmentCoordinator()));
        InvestmentCoordinator(workerVault.investmentCoordinator()).removeVault(address(tupBtcVault));
        uint256 balanceInTupAfter = tup.balanceOf(address(workerVault.investmentCoordinator()));
        emit log_named_uint("Balance in TUP Before Removal      ", balanceInTupBefore);
        emit log_named_uint("Balance in TUP Ater Removal        ", balanceInTupAfter);
        assertGt(balanceInTupAfter, balanceInTupBefore);
    }
}
