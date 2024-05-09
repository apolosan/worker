// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ITimeToken, Minion } from "./Minion.sol";

contract TimeTokenVault is ERC4626, Minion, Ownable {
    uint256 public earned;

    // POST-CONDITIONS:
    // IMPORTANT (at deployment):
    //      * deposit a minimum amount of TIME in the contract to avoid frontrunning "donation" attack
    //      * burn the share of the minimum amount deposited
    //      * enable this contract to produce TIME [enableMining()]
    constructor(address _asset, address _owner)
        ERC20("TIME Token Simple Vault", "vTIME")
        ERC4626(ERC20(_asset))
        Minion(address(this), ITimeToken(payable(_asset)))
        Ownable(_owner)
    { }

    receive() external payable { }

    fallback() external payable {
        require(msg.data.length == 0);
    }

    function _afterDeposit() private {
        _earnTime();
        _produceTime();
    }

    function _beforeWithdraw() private {
        _earnTime();
        _produceTime();
    }

    function _earnTime() private {
        if (ITimeToken(payable(asset())).withdrawableShareBalance(address(this)) > 0) {
            uint256 balanceBefore = address(this).balance;
            try ITimeToken(payable(asset())).withdrawShare() {
                if (address(this).balance > balanceBefore) {
                    earned += (address(this).balance - balanceBefore);
                }
                try ITimeToken(payable(asset())).saveTime{ value: earned }() {
                    earned = 0;
                } catch { }
            } catch { }
        }
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        _afterDeposit();
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }
        assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);
        _afterDeposit();
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }
        assets = previewRedeem(shares);
        _beforeWithdraw();
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }
        shares = previewWithdraw(assets);
        _beforeWithdraw();
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }
}
