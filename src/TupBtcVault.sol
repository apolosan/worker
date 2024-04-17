// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { FixedPoint96 } from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";

import { ITimeToken, Minion } from "./Minion.sol";
import { ISponsor } from "./ISponsor.sol";
import { ITimeIsUp } from "./ITimeIsUp.sol";
import { IUniswapV2Router02 } from "./IUniswapV2Router02.sol";
import { IWETH } from "./IWETH.sol";

contract TupBtcVault is ERC4626, Minion, Ownable {
    using Math for uint160;
    using Math for uint256;

    // AggregatorV3Interface public oracle;
    IERC20 public wBTC;
    ISponsor public sponsor;

    IUniswapV2Router02 public routerV2;
    ISwapRouter public routerV3;

    address[] private _path_BTC_ETH;
    address[] private _path_ETH_TUP;
    address[] private _path_TUP_ETH;

    address private _wETH;

    uint256 private constant CONVERSION_FEE = 100;
    uint256 private constant FEE = 2_000;

    uint24[] private UNISWAP_FEES = [500, 3_000, 10_000, 100];

    error DepositEqualsToZero();
    error ExceededAmountFromBalance(uint256 amount, uint256 currentBalance);
    error ExchangeRouterError(address routerAddress);

    // POST-CONDITIONS:
    // IMPORTANT (at deployment):
    //      * call the enableMining() function from Minion contract
    //      * deposit a minimum amount of TUP in the contract to avoid frontrunning "donation" attack
    //      * burn the share of the minimum amount deposited
    constructor(
        address _asset,
        address _wBTC,
        address _timeTokenAddress,
        address _sponsorAddress,
        address _routerV2Address,
        address _routerV3Address,
        address _owner
    )
        ERC20("TUP Vault with wBTC Strategy", "vTUP-wBTC")
        ERC4626(ERC20(_asset))
        Minion(address(this), ITimeToken(payable(_timeTokenAddress)))
        Ownable(_owner)
    {
        routerV2 = IUniswapV2Router02(payable(_routerV2Address));
        routerV3 = ISwapRouter(payable(_routerV3Address));
        sponsor = ISponsor(payable(_sponsorAddress));
        wBTC = IERC20(_wBTC);
        _wETH = routerV2.WETH();
        _path_BTC_ETH = new address[](2);
        _path_ETH_TUP = new address[](2);
        _path_TUP_ETH = new address[](2);
        _path_BTC_ETH[0] = _wBTC;
        _path_BTC_ETH[1] = routerV2.WETH();
        _path_ETH_TUP[0] = routerV2.WETH();
        _path_ETH_TUP[1] = _asset;
        _path_TUP_ETH[0] = _asset;
        _path_TUP_ETH[1] = routerV2.WETH();
    }

    receive() external payable { }

    fallback() external payable {
        require(msg.data.length == 0);
    }

    function _afterDeposit(uint256 assets, uint256 shares) private {
        _produceTime();
        _checkSponsorParticipationToUseTime();
        _exchangeFromEthToTup();
        _convertTupToBtc(IERC20(asset()).balanceOf(address(this)));
    }

    function _afterWithdraw(uint256 assets, uint256 shares) private {
        _convertTupToBtc(IERC20(asset()).balanceOf(address(this)));
    }

    function _beforeDeposit(uint256 assets, uint256 shares) private {
        assets = assets == 0 ? convertToAssets(shares) : assets;
        if (assets == 0) {
            revert DepositEqualsToZero();
        }
    }

    function _beforeWithdraw(uint256 assets, uint256 shares) private {
        _produceTime();
        _checkSponsorParticipationToUseTime();
        _exchangeFromBtcToTup(wBTC.balanceOf(address(this)));
    }

    function _checkSponsorParticipationToUseTime() private {
        uint256 balanceInTime = _timeToken.balanceOf(address(this));
        if (balanceInTime > 0) {
            if (address(sponsor) != address(0)) {
                _timeToken.approve(address(sponsor), balanceInTime);
                sponsor.extendParticipationPeriod(balanceInTime);
                if (sponsor.checkParticipation(address(this)) && sponsor.prizeToClaim(address(this)) > 0) {
                    try sponsor.claimPrize() { } catch { }
                }
            } else {
                _timeToken.spendTime(balanceInTime);
            }
        }
    }

    function _convertTupToBtc(uint256 assets) private {
        uint256 tupAmount = ITimeIsUp(asset()).accountShareBalance(address(this)) + assets.mulDiv(FEE, 10_000);
        _exchangeFromTupToBtc(tupAmount);
    }

    function _exchangeFromEthToTup() private returns (bool success) {
        if (IERC20(_wETH).balanceOf(address(this)) > 0) {
            IWETH(_wETH).withdraw(IERC20(_wETH).balanceOf(address(this)));
        }
        if (address(this).balance > 0) {
            bool dontUseSponsor = address(sponsor) == address(0);
            if (!dontUseSponsor) {
                try sponsor.swap{ value: address(this).balance }(address(0), asset(), address(this).balance) {
                    success = true;
                } catch {
                    dontUseSponsor = true;
                }
            }
            if (dontUseSponsor) {
                if (address(routerV2) == address(0) && address(routerV3) == address(0)) {
                    revert ExchangeRouterError(address(0));
                }
                try routerV2.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: address(this).balance }(
                    0, _path_ETH_TUP, address(this), block.timestamp + 300
                ) {
                    success = true;
                } catch {
                    for (uint256 i = 0; i < UNISWAP_FEES.length; i++) {
                        bytes memory path = abi.encodePacked(_wETH, UNISWAP_FEES[i], asset());
                        ISwapRouter.ExactInputParams memory params =
                            ISwapRouter.ExactInputParams(path, address(this), block.timestamp + 300, address(this).balance, 0);
                        try routerV3.exactInput{ value: address(this).balance }(params) {
                            success = true;
                            break;
                        } catch {
                            continue;
                        }
                    }
                    if (!success) {
                        revert ExchangeRouterError(address(routerV3));
                    }
                }
                if (!success) {
                    revert ExchangeRouterError(address(routerV2));
                }
            }
        }
    }

    function _exchangeFromTupToBtc(uint256 amount) private returns (bool success) {
        if (amount > IERC20(asset()).balanceOf(address(this))) {
            revert ExceededAmountFromBalance(amount, IERC20(asset()).balanceOf(address(this)));
        }
        if (address(routerV2) == address(0) && address(routerV3) == address(0)) {
            revert ExchangeRouterError(address(0));
        }
        IERC20(asset()).approve(address(routerV2), amount);
        try routerV2.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, _path_TUP_ETH, address(this), block.timestamp + 300) {
            for (uint256 j = 0; j < UNISWAP_FEES.length; j++) {
                bytes memory path = abi.encodePacked(_wETH, UNISWAP_FEES[j], address(wBTC));
                ISwapRouter.ExactInputParams memory params =
                    ISwapRouter.ExactInputParams(path, address(this), block.timestamp + 300, IERC20(_wETH).balanceOf(address(this)), 0);
                IERC20(_wETH).approve(address(routerV3), IERC20(_wETH).balanceOf(address(this)));
                try routerV3.exactInput(params) {
                    success = true;
                    break;
                } catch {
                    continue;
                }
            }
            if (!success) {
                revert ExchangeRouterError(address(routerV3));
            }
        } catch {
            for (uint256 i = 0; i < UNISWAP_FEES.length; i++) {
                for (uint256 j = 0; j < UNISWAP_FEES.length; j++) {
                    bytes memory path = abi.encodePacked(asset(), UNISWAP_FEES[i], _wETH, UNISWAP_FEES[j], address(wBTC));
                    ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams(path, address(this), block.timestamp + 300, amount, 0);
                    IERC20(asset()).approve(address(routerV3), amount);
                    try routerV3.exactInput(params) {
                        success = true;
                        break;
                    } catch {
                        continue;
                    }
                }
            }
            if (!success) {
                revert ExchangeRouterError(address(routerV3));
            }
        }
    }

    function _exchangeFromBtcToTup(uint256 amount) private returns (bool success) {
        if (amount > wBTC.balanceOf(address(this))) {
            revert ExceededAmountFromBalance(amount, wBTC.balanceOf(address(this)));
        }
        if (address(routerV2) == address(0) && address(routerV3) == address(0)) {
            revert ExchangeRouterError(address(0));
        }
        for (uint256 j = 0; j < UNISWAP_FEES.length; j++) {
            bytes memory path = abi.encodePacked(address(wBTC), UNISWAP_FEES[j], _wETH);
            ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams(path, address(this), block.timestamp + 300, amount, 0);
            wBTC.approve(address(routerV3), amount);
            try routerV3.exactInput(params) {
                success = true;
                break;
            } catch {
                continue;
            }
        }
        if (success) {
            success = _exchangeFromEthToTup();
            if (!success) {
                revert ExchangeRouterError(address(routerV2));
            }
        }
    }

    function _getAmountsOut(address[] memory pool, address[] memory path, uint256 amountIn) private view returns (uint256[] memory amounts) {
        require(path.length >= 2, "getSwapPath: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < pool.length; i++) {
            IUniswapV3Pool IPool = IUniswapV3Pool(pool[i]);
            (uint160 sqrtPriceX96,,,,,, bool unlocked) = IPool.slot0();
            require(unlocked, "Pool is Locked!");
            uint256 squaredPrice = sqrtPriceX96.mulDiv(sqrtPriceX96, FixedPoint96.Q96);
            amounts[i + 1] = amounts[i].mulDiv(
                (path[i] == IPool.token0()) ? squaredPrice : FixedPoint96.Q96, (path[i] == IPool.token0()) ? FixedPoint96.Q96 : squaredPrice
            );
            require(amounts[i + 1] != 0, "Output Zero");
        }
        return amounts;
    }

    function _queryTupAmountFromBtc(uint256 amountOfBtc) private view returns (uint256) {
        address[] memory pool = new address[](1);
        pool[0] =
            IUniswapV3Factory(IUniswapV2Router02(address(routerV3)).factory()).getPool(_path_BTC_ETH[0], _path_BTC_ETH[1], uint24(UNISWAP_FEES[0]));
        if (address(sponsor) == address(0)) {
            return routerV2.getAmountsOut(_getAmountsOut(pool, _path_BTC_ETH, amountOfBtc)[1], _path_ETH_TUP)[1];
        } else {
            return ITimeIsUp(asset()).queryAmountOptimal(_getAmountsOut(pool, _path_BTC_ETH, amountOfBtc)[1]);
        }
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        _beforeDeposit(assets, shares);
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        _afterDeposit(assets, shares);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        _beforeDeposit(assets, shares);
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }
        assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);
        _afterDeposit(assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }
        assets = previewRedeem(shares);
        _beforeWithdraw(assets, shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        _afterWithdraw(assets, shares);
    }

    function totalAssets() public view override returns (uint256) {
        if (wBTC.balanceOf(address(this)) > 0) {
            if (address(routerV3) != address(0)) {
                return IERC20(asset()).balanceOf(address(this)) + _queryTupAmountFromBtc(wBTC.balanceOf(address(this))).mulDiv(10_000 - CONVERSION_FEE, 10_000);
            } else {
                return IERC20(asset()).balanceOf(address(this));
            }
        } else {
            return IERC20(asset()).balanceOf(address(this));
        }
    }

    function updateRouterV2(address newRouterAddress) external onlyOwner {
        routerV2 = IUniswapV2Router02(newRouterAddress);
    }

    function updateRouterV3(address newRouterAddress) external onlyOwner {
        routerV3 = ISwapRouter(newRouterAddress);
    }

    function updateSponsor(address newSponsorAddress) external onlyOwner {
        sponsor = ISponsor(newSponsorAddress);
    }

    function updateWBTC(address newWBTCAddress) external onlyOwner {
        _exchangeFromBtcToTup(wBTC.balanceOf(address(this)));
        wBTC = IERC20(newWBTCAddress);
        _convertTupToBtc(IERC20(asset()).balanceOf(address(this)));
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
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