// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;
import {IRebornDefination} from "src/interfaces/IRebornPortal.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {RewardVault} from "src/RewardVault.sol";

library PortalLib {
    uint256 public constant PERSHARE_BASE = 10e18;
    // percentage base of refer reward fees
    uint256 public constant PERCENTAGE_BASE = 10000;

    enum RewardType {
        NativeToken,
        RebornToken
    }

    struct ReferrerRewardFees {
        uint16 incarnateRef1Fee;
        uint16 incarnateRef2Fee;
        uint16 vaultRef1Fee;
        uint16 vaultRef2Fee;
        uint192 _slotPlaceholder;
    }

    struct Pool {
        uint256 totalAmount;
        uint256 accRebornPerShare;
        uint256 accNativePerShare;
        uint256 epoch;
        uint256 lastUpdated;
    }

    struct Portfolio {
        uint256 accumulativeAmount;
        uint256 rebornRewardDebt;
        uint256 nativeRewardDebt;
        //
        // We do some fancy math here. Basically, any point in time, the amount
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (Amount * pool.accPerShare) - user.rewardDebt
        //
        // Whenever a user infuse or switchPool. Here's what happens:
        //   1. The pool's `accPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.

        /// @dev reward for holding the NFT when the NFT is selected
        uint256 pendingOwnerRebornReward;
        uint256 pendingOwernNativeReward;
    }

    struct AirdropConf {
        uint8 _dropOn; //                  ---
        uint40 _rebornDropInterval; //        |
        uint40 _nativeDropInterval; //        |
        uint40 _rebornDropLastUpdate; //      |
        uint40 _nativeDropLastUpdate; //      |
        uint16 _nativeDropRatio; //           |
        uint72 _rebornDropEthAmount; //    ---
    }

    struct VrfConf {
        bytes32 keyHash;
        uint64 s_subscriptionId;
        uint32 callbackGasLimit;
        uint32 numWords;
        uint16 requestConfirmations;
    }

    event DropNative(uint256 indexed tokenId);
    event DropReborn(uint256 indexed tokenId);
    event ClaimRebornDrop(uint256 indexed tokenId, uint256 rebornAmount);
    event ClaimNativeDrop(uint256 indexed tokenId, uint256 nativeAmount);
    event NewDropConf(AirdropConf conf);
    event NewVrfConf(VrfConf conf);
    event SignerUpdate(address signer, bool valid);
    event ReferReward(
        address indexed user,
        address indexed ref1,
        uint256 amount1,
        address indexed ref2,
        uint256 amount2,
        PortalLib.RewardType rewardType
    );

    /// @dev invliad chainlink vrf request id
    error InvalidRequestId(uint256);

    function _claimPoolRebornDrop(
        uint256 tokenId,
        RewardVault vault,
        mapping(uint256 => Pool) storage pools,
        mapping(address => mapping(uint256 => Portfolio)) storage portfolios
    ) external {
        Pool storage pool = pools[tokenId];
        Portfolio storage portfolio = portfolios[msg.sender][tokenId];

        if (portfolio.accumulativeAmount == 0) {
            return;
        }

        uint256 pendingReborn = (portfolio.accumulativeAmount *
            pool.accRebornPerShare) /
            PERSHARE_BASE -
            portfolio.rebornRewardDebt +
            portfolio.pendingOwnerRebornReward;

        // set current amount as debt
        portfolio.rebornRewardDebt =
            (portfolio.accumulativeAmount * pool.accRebornPerShare) /
            PERSHARE_BASE;

        // clean up reward as owner
        portfolio.pendingOwnerRebornReward = 0;

        /// @dev send drop
        if (pendingReborn != 0) {
            vault.reward(msg.sender, pendingReborn);
        }

        emit ClaimRebornDrop(tokenId, pendingReborn);
    }

    function _claimPoolNativeDrop(
        uint256 tokenId,
        mapping(uint256 => Pool) storage pools,
        mapping(address => mapping(uint256 => Portfolio)) storage portfolios
    ) external {
        Pool storage pool = pools[tokenId];
        Portfolio storage portfolio = portfolios[msg.sender][tokenId];

        if (portfolio.accumulativeAmount == 0) {
            return;
        }

        uint256 pendingNative = (portfolio.accumulativeAmount *
            pool.accNativePerShare) /
            PERSHARE_BASE -
            portfolio.nativeRewardDebt +
            portfolio.pendingOwernNativeReward;

        // set current amount as debt
        portfolio.nativeRewardDebt =
            (portfolio.accumulativeAmount * pool.accNativePerShare) /
            PERSHARE_BASE;

        // clean up reward as owner
        portfolio.pendingOwernNativeReward = 0;

        /// @dev send drop
        if (pendingNative != 0) {
            payable(msg.sender).transfer(pendingNative);

            emit ClaimNativeDrop(tokenId, pendingNative);
        }
    }

    function _flattenRewardDebt(
        Pool storage pool,
        Portfolio storage portfolio
    ) external {
        // flatten native reward
        portfolio.nativeRewardDebt =
            (portfolio.accumulativeAmount * pool.accNativePerShare) /
            PERSHARE_BASE;

        // flatten reborn reward
        portfolio.rebornRewardDebt =
            (portfolio.accumulativeAmount * pool.accRebornPerShare) /
            PERSHARE_BASE;
    }

    /**
     * @dev calculate drop from a pool
     */
    function _calculatePoolDrop(
        uint256 tokenId,
        mapping(uint256 => Pool) storage pools,
        mapping(address => mapping(uint256 => Portfolio)) storage portfolios
    ) public view returns (uint256 pendingNative, uint256 pendingReborn) {
        Pool storage pool = pools[tokenId];
        Portfolio storage portfolio = portfolios[msg.sender][tokenId];

        // if no portfolio, no pending reward
        if (portfolio.accumulativeAmount == 0) {
            return (pendingNative, pendingReborn);
        }

        pendingNative =
            (portfolio.accumulativeAmount * pool.accNativePerShare) /
            PERSHARE_BASE -
            portfolio.nativeRewardDebt +
            portfolio.pendingOwernNativeReward;

        pendingReborn =
            (portfolio.accumulativeAmount * pool.accRebornPerShare) /
            PERSHARE_BASE -
            portfolio.rebornRewardDebt +
            portfolio.pendingOwnerRebornReward;
    }

    /**
     * @dev read pending reward from specific pool
     * @param tokenIds tokenId array of the pools
     */
    function _pendingDrop(
        mapping(uint256 => Pool) storage pools,
        mapping(address => mapping(uint256 => Portfolio)) storage portfolios,
        uint256[] memory tokenIds
    ) external view returns (uint256 pNative, uint256 pReborn) {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (uint256 n, uint256 r) = _calculatePoolDrop(
                tokenIds[i],
                pools,
                portfolios
            );
            pNative += n;
            pReborn += r;
        }
    }

    function _directDropNativeTokenIds(
        uint256[] memory tokenIds,
        AirdropConf storage _dropConf,
        mapping(uint256 => Pool) storage pools,
        mapping(address => mapping(uint256 => Portfolio)) storage portfolios
    ) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            // if tokenId is zero , return
            if (tokenId == 0) {
                return;
            }

            Pool storage pool = pools[tokenId];

            // if no one tribute, return
            // as it's loof from high tvl to low tvl
            if (pool.totalAmount == 0) {
                return;
            }

            uint256 dropAmount = (_dropConf._nativeDropRatio *
                address(this).balance) / PortalLib.PERCENTAGE_BASE;

            // 80% to pool
            pool.accNativePerShare +=
                (((dropAmount * 4) / 5) * PortalLib.PERSHARE_BASE) /
                PERCENTAGE_BASE /
                pool.totalAmount;

            // 20% to owner
            address owner = IERC721(address(this)).ownerOf(tokenId);
            Portfolio storage portfolio = portfolios[owner][tokenId];
            portfolio.pendingOwernNativeReward += (dropAmount * 1) / 5;

            emit DropNative(tokenId);
        }
    }

    function _directDropRebornTokenIds(
        uint256[] memory tokenIds,
        AirdropConf storage _dropConf,
        mapping(uint256 => Pool) storage pools,
        mapping(address => mapping(uint256 => Portfolio)) storage portfolios
    ) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            // if tokenId is zero, continue
            if (tokenId == 0) {
                return;
            }
            Pool storage pool = pools[tokenId];

            // if no one tribute, continue
            // as it's loof from high tvl to low tvl
            if (pool.totalAmount == 0) {
                return;
            }

            uint256 dropAmount = _dropConf._rebornDropEthAmount * 1 ether;

            // 80% to pool
            pool.accRebornPerShare +=
                (((dropAmount * 4) / 5) * PortalLib.PERSHARE_BASE) /
                pool.totalAmount;

            // 20% to owner
            address owner = IERC721(address(this)).ownerOf(tokenId);
            Portfolio storage portfolio = portfolios[owner][tokenId];
            portfolio.pendingOwnerRebornReward += (dropAmount * 1) / 5;

            emit DropNative(tokenId);
        }
    }

    function _toLastHour(uint256 timestamp) internal pure returns (uint256) {
        return timestamp - (timestamp % (1 hours));
    }

    /**
     * @dev update signers
     * @param toAdd list of to be added signer
     * @param toRemove list of to be removed signer
     */
    function _updateSigners(
        mapping(address => bool) storage signers,
        address[] calldata toAdd,
        address[] calldata toRemove
    ) public {
        for (uint256 i = 0; i < toAdd.length; i++) {
            signers[toAdd[i]] = true;
            emit SignerUpdate(toAdd[i], true);
        }
        for (uint256 i = 0; i < toRemove.length; i++) {
            delete signers[toRemove[i]];
            emit SignerUpdate(toRemove[i], false);
        }
    }

    /**
     * @dev returns referrer and referer reward
     * @return ref1  level1 of referrer. direct referrer
     * @return ref1Reward  level 1 referrer reward
     * @return ref2  level2 of referrer. referrer's referrer
     * @return ref2Reward  level 2 referrer reward
     */
    function _calculateReferReward(
        mapping(address => address) storage referrals,
        ReferrerRewardFees storage rewardFees,
        address account,
        uint256 amount,
        RewardType rewardType
    )
        public
        view
        returns (
            address ref1,
            uint256 ref1Reward,
            address ref2,
            uint256 ref2Reward
        )
    {
        ref1 = referrals[account];
        ref2 = referrals[ref1];

        if (rewardType == RewardType.NativeToken) {
            ref1Reward = ref1 == address(0)
                ? 0
                : (amount * rewardFees.incarnateRef1Fee) /
                    PortalLib.PERCENTAGE_BASE;
            ref2Reward = ref2 == address(0)
                ? 0
                : (amount * rewardFees.incarnateRef2Fee) /
                    PortalLib.PERCENTAGE_BASE;
        }

        if (rewardType == RewardType.RebornToken) {
            ref1Reward = ref1 == address(0)
                ? 0
                : (amount * rewardFees.vaultRef1Fee) /
                    PortalLib.PERCENTAGE_BASE;
            ref2Reward = ref2 == address(0)
                ? 0
                : (amount * rewardFees.vaultRef2Fee) /
                    PortalLib.PERCENTAGE_BASE;
        }
    }

    /**
     * @notice mul 100 when set. eg: 8% -> 800 18%-> 1800
     * @dev set percentage of referrer reward
     * @param rewardType 0: incarnate reward 1: engrave reward
     */
    function _setReferrerRewardFee(
        ReferrerRewardFees storage rewardFees,
        uint16 refL1Fee,
        uint16 refL2Fee,
        PortalLib.RewardType rewardType
    ) external {
        if (rewardType == PortalLib.RewardType.NativeToken) {
            rewardFees.incarnateRef1Fee = refL1Fee;
            rewardFees.incarnateRef2Fee = refL2Fee;
        } else if (rewardType == PortalLib.RewardType.RebornToken) {
            rewardFees.vaultRef1Fee = refL1Fee;
            rewardFees.vaultRef2Fee = refL2Fee;
        }
    }

    /**
     * @dev send NativeToken to referrers
     */
    function _sendRewardToRefs(
        mapping(address => address) storage referrals,
        ReferrerRewardFees storage rewardFees,
        address account,
        uint256 amount
    ) public {
        (
            address ref1,
            uint256 ref1Reward,
            address ref2,
            uint256 ref2Reward
        ) = _calculateReferReward(
                referrals,
                rewardFees,
                account,
                amount,
                PortalLib.RewardType.NativeToken
            );

        if (ref1Reward > 0) {
            payable(ref1).transfer(ref1Reward);
        }

        if (ref2Reward > 0) {
            payable(ref2).transfer(ref2Reward);
        }

        emit ReferReward(
            account,
            ref1,
            ref1Reward,
            ref2,
            ref2Reward,
            PortalLib.RewardType.NativeToken
        );
    }

    /**
     * @dev vault $REBORN token to referrers
     */
    function _vaultRewardToRefs(
        mapping(address => address) storage referrals,
        ReferrerRewardFees storage rewardFees,
        RewardVault vault,
        address account,
        uint256 amount
    ) public {
        (
            address ref1,
            uint256 ref1Reward,
            address ref2,
            uint256 ref2Reward
        ) = _calculateReferReward(
                referrals,
                rewardFees,
                account,
                amount,
                PortalLib.RewardType.RebornToken
            );

        if (ref1Reward > 0) {
            vault.reward(ref1, ref1Reward);
        }

        if (ref2Reward > 0) {
            vault.reward(ref2, ref2Reward);
        }

        emit ReferReward(
            account,
            ref1,
            ref1Reward,
            ref2,
            ref2Reward,
            PortalLib.RewardType.RebornToken
        );
    }
}