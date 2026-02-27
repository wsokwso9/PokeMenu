// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Zephyr batch #12 — PokeMenu: digital collectible set registry and launchpad; mints from linked PokeBro NFT up to cap.
 * @dev Treasury, vault, and launchpadWallet are immutable. PokeBro NFT address set by owner after deploy. ReentrancyGuard and Pausable for mainnet safety.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/Pausable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

interface IPokeBroNft {
    function mint(address to, uint256 tokenId) external;
    function totalSupply() external view returns (uint256);
}

contract PokeMenu is ReentrancyGuard, Pausable, Ownable {

    event SetCreated(uint256 indexed setId, bytes32 nameHash, uint256 maxPerSet, uint256 priceWei, address indexed creator, uint256 atBlock);
    event SetConfigUpdated(uint256 indexed setId, uint256 priceWei, bool saleOpen, uint256 atBlock);
    event CollectibleMinted(uint256 indexed setId, address indexed to, uint256 tokenId, uint256 atBlock);
    event LaunchpadSaleOpened(uint256 indexed setId, uint256 atBlock);
    event LaunchpadSaleClosed(uint256 indexed setId, uint256 atBlock);
    event PokeBroNftSet(address indexed previous, address indexed current, uint256 atBlock);
    event TreasurySweep(address indexed to, uint256 amountWei, uint256 atBlock);
    event VaultSweep(address indexed to, uint256 amountWei, uint256 atBlock);
    event LaunchpadSweep(address indexed to, uint256 amountWei, uint256 atBlock);
    event PlatformPaused(bool paused, uint256 atBlock);
    event FeeBpsUpdated(uint256 previousBps, uint256 newBps, uint256 atBlock);
    event BatchMinted(uint256 indexed setId, address indexed to, uint256 count, uint256 startTokenId, uint256 atBlock);
    event SetCreatorUpdated(uint256 indexed setId, address indexed previous, address indexed current, uint256 atBlock);
    event SetMaxPerSetUpdated(uint256 indexed setId, uint256 previous, uint256 current, uint256 atBlock);
    event SetNameHashUpdated(uint256 indexed setId, bytes32 previous, bytes32 current, uint256 atBlock);
    event SnapshotRecorded(uint256 indexed setId, uint256 mintedFromSet, uint256 atBlock);
    event ConfigFrozen(uint256 atBlock);
    event LaunchpadDomainSet(bytes32 domain, uint256 atBlock);

    error PMU_ZeroAddress();
    error PMU_ZeroAmount();
    error PMU_PlatformPaused();
    error PMU_SetNotFound();
    error PMU_SaleNotOpen();
    error PMU_SaleAlreadyOpen();
    error PMU_SaleAlreadyClosed();
    error PMU_ExceedsSetSupply();
    error PMU_ExceedsGlobalSupply();
    error PMU_InsufficientPayment();
    error PMU_InvalidFeeBps();
    error PMU_TransferFailed();
    error PMU_Reentrancy();
    error PMU_NotCreator();
    error PMU_MaxSetsReached();
    error PMU_PokeBroNotSet();
    error PMU_ArrayLengthMismatch();
    error PMU_BatchTooLarge();
    error PMU_ZeroMint();
    error PMU_InvalidSetId();
    error PMU_InvalidIndex();

    uint256 public constant PMU_BPS_BASE = 10000;
    uint256 public constant PMU_MAX_FEE_BPS = 400;
    uint256 public constant PMU_MAX_SETS = 64;
    uint256 public constant PMU_POKEBRO_CAP = 100000;
    uint256 public constant PMU_MAX_MINT_PER_TX = 24;
    uint256 public constant PMU_SET_SALT = 0xE9b2D4f6A8c0E2b4D6f8A0c2E4b6D8f0A2c4E6;
    bytes32 public constant PMU_LAUNCHPAD_DOMAIN = keccak256("PokeMenu.Launchpad.v1");

    address public immutable treasury;
    address public immutable vault;
    address public immutable launchpadWallet;
    uint256 public immutable deployBlock;
    bytes32 public immutable genesisHash;

    address public pokeBroNft;
    uint256 public setCounter;
    uint256 public feeBps;
    uint256 public nextTokenId;
    bool public platformPaused;

    struct SetInfo {
        bytes32 nameHash;
        uint256 maxPerSet;
        uint256 priceWei;
        address creator;
        uint256 mintedFromSet;
        bool saleOpen;
        uint256 createdAtBlock;
    }

    struct SetSnapshot {
        uint256 setId;
        uint256 mintedFromSet;
        uint256 atBlock;
    }
    mapping(uint256 => SetInfo) public sets;
    mapping(uint256 => uint256) public tokenIdToSetId;
    mapping(uint256 => uint256[]) private _setSnapshotIds;
    mapping(uint256 => SetSnapshot) public setSnapshots;
    uint256[] private _setIds;
    uint256 public snapshotSequence;

    modifier whenNotPaused() {
        if (platformPaused) revert PMU_PlatformPaused();
        _;
    }

    constructor() {
        treasury = address(0x3F7a2C5e8B0d4F6A9c1E3b7D0f2A5C8e1B4D7F0);
        vault = address(0x6C1e4A8d0F2b6C9e3A7d1F5b9E2c6A0d4F8b2E5);
        launchpadWallet = address(0x5B9d1F3a7C0e4B8D2f6A0c4E8b2D6F0a3C7e1B5);
        deployBlock = block.number;
        genesisHash = keccak256(abi.encodePacked("PokeMenu", block.chainid, block.prevrandao, PMU_SET_SALT));
        nextTokenId = 0;
        feeBps = 85;
    }

    function setPokeBroNft(address nft) external onlyOwner {
        if (nft == address(0)) revert PMU_ZeroAddress();
        address prev = pokeBroNft;
        pokeBroNft = nft;
        emit PokeBroNftSet(prev, nft, block.number);
    }

    function setPlatformPaused(bool paused) external onlyOwner {
        platformPaused = paused;
        emit PlatformPaused(paused, block.number);
    }

    function setFeeBps(uint256 bps) external onlyOwner {
        if (bps > PMU_MAX_FEE_BPS) revert PMU_InvalidFeeBps();
        uint256 prev = feeBps;
        feeBps = bps;
        emit FeeBpsUpdated(prev, bps, block.number);
    }

    function createSet(bytes32 nameHash, uint256 maxPerSet, uint256 priceWei) external onlyOwner returns (uint256 setId) {
        if (setCounter >= PMU_MAX_SETS) revert PMU_MaxSetsReached();
        setId = ++setCounter;
        sets[setId] = SetInfo({
            nameHash: nameHash,
            maxPerSet: maxPerSet,
            priceWei: priceWei,
            creator: msg.sender,
            mintedFromSet: 0,
            saleOpen: false,
            createdAtBlock: block.number
        });
        _setIds.push(setId);
        emit SetCreated(setId, nameHash, maxPerSet, priceWei, msg.sender, block.number);
        return setId;
    }

    function openSale(uint256 setId) external onlyOwner {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        if (s.saleOpen) revert PMU_SaleAlreadyOpen();
        s.saleOpen = true;
        emit LaunchpadSaleOpened(setId, block.number);
    }

    function closeSale(uint256 setId) external onlyOwner {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        if (!s.saleOpen) revert PMU_SaleAlreadyClosed();
        s.saleOpen = false;
        emit LaunchpadSaleClosed(setId, block.number);
    }

    function updateSetPrice(uint256 setId, uint256 priceWei) external onlyOwner {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        sets[setId].priceWei = priceWei;
        emit SetConfigUpdated(setId, priceWei, sets[setId].saleOpen, block.number);
    }

    function mintFromSet(uint256 setId, uint256 count) external payable nonReentrant whenNotPaused returns (uint256 startTokenId) {
        if (pokeBroNft == address(0)) revert PMU_PokeBroNotSet();
        if (count == 0) revert PMU_ZeroMint();
        if (count > PMU_MAX_MINT_PER_TX) revert PMU_BatchTooLarge();
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        if (!s.saleOpen) revert PMU_SaleNotOpen();
        if (s.mintedFromSet + count > s.maxPerSet) revert PMU_ExceedsSetSupply();
        if (nextTokenId + count > PMU_POKEBRO_CAP) revert PMU_ExceedsGlobalSupply();
        uint256 totalPrice = s.priceWei * count;
        if (msg.value < totalPrice) revert PMU_InsufficientPayment();
        uint256 feeWei = (totalPrice * feeBps) / PMU_BPS_BASE;
        uint256 toCreator = (totalPrice - feeWei) / 2;
        uint256 toLaunchpad = totalPrice - feeWei - toCreator;
        if (feeWei > 0) _safeSend(treasury, feeWei);
        if (toCreator > 0) _safeSend(s.creator, toCreator);
        if (toLaunchpad > 0) _safeSend(launchpadWallet, toLaunchpad);
        startTokenId = nextTokenId;
        IPokeBroNft nft = IPokeBroNft(pokeBroNft);
        for (uint256 i = 0; i < count; i++) {
            tokenIdToSetId[nextTokenId] = setId;
            nft.mint(msg.sender, nextTokenId);
            emit CollectibleMinted(setId, msg.sender, nextTokenId, block.number);
            nextTokenId++;
        }
        s.mintedFromSet += count;
        snapshotSequence++;
        setSnapshots[snapshotSequence] = SetSnapshot({ setId: setId, mintedFromSet: s.mintedFromSet, atBlock: block.number });
        _setSnapshotIds[setId].push(snapshotSequence);
        emit SnapshotRecorded(setId, s.mintedFromSet, block.number);
        emit BatchMinted(setId, msg.sender, count, startTokenId, block.number);
        return startTokenId;
    }

    function _safeSend(address to, uint256 amount) internal {
        if (to == address(0) || amount == 0) return;
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert PMU_TransferFailed();
    }

    function sweepTreasury(uint256 amountWei) external onlyOwner nonReentrant {
        if (amountWei == 0) revert PMU_ZeroAmount();
        if (address(this).balance < amountWei) revert PMU_InsufficientPayment();
        _safeSend(treasury, amountWei);
        emit TreasurySweep(treasury, amountWei, block.number);
    }

    function sweepVault(uint256 amountWei) external onlyOwner nonReentrant {
        if (amountWei == 0) revert PMU_ZeroAmount();
        if (address(this).balance < amountWei) revert PMU_InsufficientPayment();
        _safeSend(vault, amountWei);
        emit VaultSweep(vault, amountWei, block.number);
    }

    function sweepLaunchpad(uint256 amountWei) external onlyOwner nonReentrant {
        if (amountWei == 0) revert PMU_ZeroAmount();
        if (address(this).balance < amountWei) revert PMU_InsufficientPayment();
        _safeSend(launchpadWallet, amountWei);
        emit LaunchpadSweep(launchpadWallet, amountWei, block.number);
    }

    function getSetInfo(uint256 setId) external view returns (
        bytes32 nameHash,
        uint256 maxPerSet,
        uint256 priceWei,
        address creator,
        uint256 mintedFromSet,
        bool saleOpen,
        uint256 createdAtBlock
    ) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        return (s.nameHash, s.maxPerSet, s.priceWei, s.creator, s.mintedFromSet, s.saleOpen, s.createdAtBlock);
    }

    function getSetIds() external view returns (uint256[] memory) {
        return _setIds;
    }

    function getConfig() external view returns (address nft, uint256 nextId, uint256 feeBps_, bool paused_) {
        return (pokeBroNft, nextTokenId, feeBps, platformPaused);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function updateSetCreator(uint256 setId, address newCreator) external onlyOwner {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        if (newCreator == address(0)) revert PMU_ZeroAddress();
        address prev = sets[setId].creator;
        sets[setId].creator = newCreator;
        emit SetCreatorUpdated(setId, prev, newCreator, block.number);
    }

    function updateSetMaxPerSet(uint256 setId, uint256 maxPerSet) external onlyOwner {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        uint256 prev = sets[setId].maxPerSet;
        if (maxPerSet < sets[setId].mintedFromSet) revert PMU_ExceedsSetSupply();
        sets[setId].maxPerSet = maxPerSet;
        emit SetMaxPerSetUpdated(setId, prev, maxPerSet, block.number);
    }

    function updateSetNameHash(uint256 setId, bytes32 nameHash) external onlyOwner {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        bytes32 prev = sets[setId].nameHash;
        sets[setId].nameHash = nameHash;
        emit SetNameHashUpdated(setId, prev, nameHash, block.number);
    }

    function batchCreateSets(bytes32[] calldata nameHashes, uint256[] calldata maxPerSets, uint256[] calldata pricesWei) external onlyOwner returns (uint256[] memory setIds) {
        if (nameHashes.length != maxPerSets.length || nameHashes.length != pricesWei.length) revert PMU_ArrayLengthMismatch();
        if (nameHashes.length > 12) revert PMU_BatchTooLarge();
        setIds = new uint256[](nameHashes.length);
        for (uint256 i = 0; i < nameHashes.length; i++) {
            if (setCounter >= PMU_MAX_SETS) revert PMU_MaxSetsReached();
            uint256 setId = ++setCounter;
            sets[setId] = SetInfo({
                nameHash: nameHashes[i],
                maxPerSet: maxPerSets[i],
                priceWei: pricesWei[i],
                creator: msg.sender,
                mintedFromSet: 0,
                saleOpen: false,
                createdAtBlock: block.number
            });
            _setIds.push(setId);
            setIds[i] = setId;
            emit SetCreated(setId, nameHashes[i], maxPerSets[i], pricesWei[i], msg.sender, block.number);
        }
        return setIds;
    }

    function getSetStruct(uint256 setId) external view returns (SetInfo memory) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId];
    }

    function getSetSnapshot(uint256 snapshotId) external view returns (SetSnapshot memory) {
        return setSnapshots[snapshotId];
    }

    function getSetSnapshotCount(uint256 setId) external view returns (uint256) {
        return _setSnapshotIds[setId].length;
    }

    function getSetSnapshotIdAt(uint256 setId, uint256 index) external view returns (uint256) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return _setSnapshotIds[setId][index];
    }

    function getTreasuryAddress() external view returns (address) { return treasury; }
    function getVaultAddress() external view returns (address) { return vault; }
    function getLaunchpadWalletAddress() external view returns (address) { return launchpadWallet; }
    function getPokeBroNft() external view returns (address) { return pokeBroNft; }
    function getNextTokenId() external view returns (uint256) { return nextTokenId; }
    function getSetCounter() external view returns (uint256) { return setCounter; }
    function getFeeBps() external view returns (uint256) { return feeBps; }
    function getPlatformPaused() external view returns (bool) { return platformPaused; }
    function getDeployBlock() external view returns (uint256) { return deployBlock; }
    function getGenesisHash() external view returns (bytes32) { return genesisHash; }
    function getSnapshotSequence() external view returns (uint256) { return snapshotSequence; }
    function setCount() external view returns (uint256) { return _setIds.length; }
    function setAt(uint256 index) external view returns (uint256) {
        if (index >= _setIds.length) revert PMU_InvalidIndex();
        return _setIds[index];
    }
    function getSetIdsLength() external view returns (uint256) { return _setIds.length; }
    function bpsBase() external pure returns (uint256) { return PMU_BPS_BASE; }
    function maxFeeBps() external pure returns (uint256) { return PMU_MAX_FEE_BPS; }
    function maxSets() external pure returns (uint256) { return PMU_MAX_SETS; }
    function pokebroCap() external pure returns (uint256) { return PMU_POKEBRO_CAP; }
    function maxMintPerTx() external pure returns (uint256) { return PMU_MAX_MINT_PER_TX; }
    function setSalt() external pure returns (uint256) { return PMU_SET_SALT; }
    function launchpadDomain() external pure returns (bytes32) { return PMU_LAUNCHPAD_DOMAIN; }
    function getSetNameHash(uint256 setId) external view returns (bytes32) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].nameHash;
    }
    function getSetMaxPerSet(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].maxPerSet;
    }
    function getSetPriceWei(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].priceWei;
    }
    function getSetCreator(uint256 setId) external view returns (address) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].creator;
    }
    function getSetMintedFromSet(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].mintedFromSet;
    }
    function getSetSaleOpen(uint256 setId) external view returns (bool) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].saleOpen;
    }
    function getSetCreatedAtBlock(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].createdAtBlock;
    }
    function getSetIdForToken(uint256 tokenId) external view returns (uint256) {
        return tokenIdToSetId[tokenId];
    }
    function canMintFromSet(uint256 setId, uint256 count) external view returns (bool) {
        if (pokeBroNft == address(0)) return false;
        if (setId == 0 || setId > setCounter) return false;
        SetInfo storage s = sets[setId];
        if (!s.saleOpen) return false;
        if (s.mintedFromSet + count > s.maxPerSet) return false;
        if (nextTokenId + count > PMU_POKEBRO_CAP) return false;
        return true;
    }
    function estimatePrice(uint256 setId, uint256 count) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].priceWei * count;
    }
    function estimateFee(uint256 setId, uint256 count) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        uint256 total = sets[setId].priceWei * count;
        return (total * feeBps) / PMU_BPS_BASE;
    }
    function getRemainingSetSupply(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        return s.maxPerSet > s.mintedFromSet ? s.maxPerSet - s.mintedFromSet : 0;
    }
    function getRemainingGlobalSupply() external view returns (uint256) {
        return nextTokenId >= PMU_POKEBRO_CAP ? 0 : PMU_POKEBRO_CAP - nextTokenId;
    }
    function contractBalance() external view returns (uint256) { return address(this).balance; }
    function emitConfigFrozen() external onlyOwner { emit ConfigFrozen(block.number); }

    function _recordSnapshot(uint256 setId) internal {
        snapshotSequence++;
        setSnapshots[snapshotSequence] = SetSnapshot({ setId: setId, mintedFromSet: sets[setId].mintedFromSet, atBlock: block.number });
        _setSnapshotIds[setId].push(snapshotSequence);
    }

    function treasuryAddress() external view returns (address) { return treasury; }
    function vaultAddress() external view returns (address) { return vault; }
    function launchpadWalletAddress() external view returns (address) { return launchpadWallet; }
    function pokeBroNftAddress() external view returns (address) { return pokeBroNft; }
    function nextTokenIdValue() external view returns (uint256) { return nextTokenId; }
    function setCounterValue() external view returns (uint256) { return setCounter; }
    function feeBpsValue() external view returns (uint256) { return feeBps; }
    function platformPausedStatus() external view returns (bool) { return platformPaused; }
    function deployBlockValue() external view returns (uint256) { return deployBlock; }
    function genesisHashValue() external view returns (bytes32) { return genesisHash; }
    function snapshotSequenceValue() external view returns (uint256) { return snapshotSequence; }
    function setIdsLength() external view returns (uint256) { return _setIds.length; }
    function bpsBaseValue() external pure returns (uint256) { return PMU_BPS_BASE; }
    function maxFeeBpsValue() external pure returns (uint256) { return PMU_MAX_FEE_BPS; }
    function maxSetsValue() external pure returns (uint256) { return PMU_MAX_SETS; }
    function pokebroCapValue() external pure returns (uint256) { return PMU_POKEBRO_CAP; }
    function maxMintPerTxValue() external pure returns (uint256) { return PMU_MAX_MINT_PER_TX; }
    function setSaltValue() external pure returns (uint256) { return PMU_SET_SALT; }
    function launchpadDomainValue() external pure returns (bytes32) { return PMU_LAUNCHPAD_DOMAIN; }
    function setNameHash(uint256 setId) external view returns (bytes32) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].nameHash;
    }
    function setMaxPerSet(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].maxPerSet;
    }
    function setPriceWei(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].priceWei;
    }
    function setCreator(uint256 setId) external view returns (address) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].creator;
    }
    function setMintedFromSet(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].mintedFromSet;
    }
    function setSaleOpen(uint256 setId) external view returns (bool) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].saleOpen;
    }
    function setCreatedAtBlock(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].createdAtBlock;
    }
    function tokenIdToSetIdMapping(uint256 tokenId) external view returns (uint256) {
        return tokenIdToSetId[tokenId];
    }
    function remainingSupplyForSet(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        return s.maxPerSet > s.mintedFromSet ? s.maxPerSet - s.mintedFromSet : 0;
    }
    function remainingGlobalSupply() external view returns (uint256) {
        return nextTokenId >= PMU_POKEBRO_CAP ? 0 : PMU_POKEBRO_CAP - nextTokenId;
    }
    function getSetIdsSlice(uint256 offset, uint256 limit) external view returns (uint256[] memory out) {
        uint256 len = _setIds.length;
        if (offset >= len) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 n = end - offset;
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _setIds[offset + i];
        return out;
    }
    function getSetInfoStruct(uint256 setId) external view returns (SetInfo memory) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId];
    }
    function getSetSnapshotStruct(uint256 snapshotId) external view returns (SetSnapshot memory) {
        return setSnapshots[snapshotId];
    }
    function getSetSnapshotIds(uint256 setId) external view returns (uint256[] memory) {
        return _setSnapshotIds[setId];
    }
    function isSetSaleOpen(uint256 setId) external view returns (bool) {
        return setId != 0 && setId <= setCounter && sets[setId].saleOpen;
    }
    function isSetExists(uint256 setId) external view returns (bool) {
        return setId != 0 && setId <= setCounter;
    }
    function computeTotalPrice(uint256 setId, uint256 count) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].priceWei * count;
    }
    function computeFeeWei(uint256 totalWei) external view returns (uint256) {
        return (totalWei * feeBps) / PMU_BPS_BASE;
    }
    function computeCreatorShare(uint256 totalWei, uint256 feeWei) external pure returns (uint256) {
        return (totalWei - feeWei) / 2;
    }
    function computeLaunchpadShare(uint256 totalWei, uint256 feeWei, uint256 creatorShare) external pure returns (uint256) {
        return totalWei - feeWei - creatorShare;
    }
    function getImmutableAddresses() external view returns (address treasury_, address vault_, address launchpad_) {
        return (treasury, vault, launchpadWallet);
    }
    function getConfigStruct() external view returns (address nft_, uint256 nextId_, uint256 feeBps_, bool paused_, uint256 setCounter_) {
        return (pokeBroNft, nextTokenId, feeBps, platformPaused, setCounter);
    }
    function getSetAt(uint256 index) external view returns (uint256) {
        if (index >= _setIds.length) revert PMU_InvalidIndex();
        return _setIds[index];
    }
    function getSnapshotAt(uint256 setId, uint256 index) external view returns (uint256 snapshotId) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return _setSnapshotIds[setId][index];
    }
    function getSnapshotStructById(uint256 snapshotId) external view returns (SetSnapshot memory) {
        return setSnapshots[snapshotId];
    }
    function validateSetId(uint256 setId) external view returns (bool) {
        return setId != 0 && setId <= setCounter;
    }
    function validateMintParams(uint256 setId, uint256 count) external view returns (bool) {
        if (pokeBroNft == address(0)) return false;
        if (setId == 0 || setId > setCounter) return false;
        if (count == 0 || count > PMU_MAX_MINT_PER_TX) return false;
        SetInfo storage s = sets[setId];
        if (!s.saleOpen) return false;
        if (s.mintedFromSet + count > s.maxPerSet) return false;
        if (nextTokenId + count > PMU_POKEBRO_CAP) return false;
        return true;
    }
    function getSetInfoFull(uint256 setId) external view returns (
        bytes32 nameHash_,
        uint256 maxPerSet_,
        uint256 priceWei_,
        address creator_,
        uint256 mintedFromSet_,
        bool saleOpen_,
        uint256 createdAtBlock_,
        uint256 remainingSupply_
    ) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        uint256 rem = s.maxPerSet > s.mintedFromSet ? s.maxPerSet - s.mintedFromSet : 0;
        return (s.nameHash, s.maxPerSet, s.priceWei, s.creator, s.mintedFromSet, s.saleOpen, s.createdAtBlock, rem);
    }
    function getAllSetIds() external view returns (uint256[] memory) {
        return _setIds;
    }
    function getSetSnapshotCountForSet(uint256 setId) external view returns (uint256) {
        return _setSnapshotIds[setId].length;
    }
    function getSetSnapshotIdForSetAt(uint256 setId, uint256 index) external view returns (uint256) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return _setSnapshotIds[setId][index];
    }
    function getSetSnapshotStructBySnapshot(uint256 snapshotId) external view returns (SetSnapshot memory) {
        return setSnapshots[snapshotId];
    }
    function fetchSetNameHash(uint256 setId) external view returns (bytes32) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].nameHash;
    }
    function fetchSetMaxPerSet(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].maxPerSet;
    }
    function fetchSetPriceWei(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].priceWei;
    }
    function fetchSetCreator(uint256 setId) external view returns (address) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].creator;
    }
    function fetchSetMintedFromSet(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].mintedFromSet;
    }
    function fetchSetSaleOpen(uint256 setId) external view returns (bool) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].saleOpen;
    }
    function fetchSetCreatedAtBlock(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].createdAtBlock;
    }
    function fetchTokenIdToSetId(uint256 tokenId) external view returns (uint256) {
        return tokenIdToSetId[tokenId];
    }
    function fetchRemainingSetSupply(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        return s.maxPerSet > s.mintedFromSet ? s.maxPerSet - s.mintedFromSet : 0;
    }
    function fetchRemainingGlobalSupply() external view returns (uint256) {
        return nextTokenId >= PMU_POKEBRO_CAP ? 0 : PMU_POKEBRO_CAP - nextTokenId;
    }
    function fetchTreasury() external view returns (address) { return treasury; }
    function fetchVault() external view returns (address) { return vault; }
    function fetchLaunchpadWallet() external view returns (address) { return launchpadWallet; }
    function fetchPokeBroNft() external view returns (address) { return pokeBroNft; }
    function fetchNextTokenId() external view returns (uint256) { return nextTokenId; }
    function fetchSetCounter() external view returns (uint256) { return setCounter; }
    function fetchFeeBps() external view returns (uint256) { return feeBps; }
    function fetchPlatformPaused() external view returns (bool) { return platformPaused; }
    function fetchDeployBlock() external view returns (uint256) { return deployBlock; }
    function fetchGenesisHash() external view returns (bytes32) { return genesisHash; }
    function fetchSnapshotSequence() external view returns (uint256) { return snapshotSequence; }
    function fetchSetCount() external view returns (uint256) { return _setIds.length; }
    function fetchSetIdAt(uint256 index) external view returns (uint256) {
        if (index >= _setIds.length) revert PMU_InvalidIndex();
        return _setIds[index];
    }
    function fetchBpsBase() external pure returns (uint256) { return PMU_BPS_BASE; }
    function fetchMaxFeeBps() external pure returns (uint256) { return PMU_MAX_FEE_BPS; }
    function fetchMaxSets() external pure returns (uint256) { return PMU_MAX_SETS; }
    function fetchPokebroCap() external pure returns (uint256) { return PMU_POKEBRO_CAP; }
    function fetchMaxMintPerTx() external pure returns (uint256) { return PMU_MAX_MINT_PER_TX; }
    function fetchSetSalt() external pure returns (uint256) { return PMU_SET_SALT; }
    function fetchLaunchpadDomain() external pure returns (bytes32) { return PMU_LAUNCHPAD_DOMAIN; }
    function getSetInfoShort(uint256 setId) external view returns (uint256 priceWei_, uint256 mintedFromSet_, bool saleOpen_) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        return (s.priceWei, s.mintedFromSet, s.saleOpen);
    }
    function getSetInfoMedium(uint256 setId) external view returns (bytes32 nameHash_, uint256 priceWei_, address creator_, bool saleOpen_) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        return (s.nameHash, s.priceWei, s.creator, s.saleOpen);
    }
    function getSetInfoLong(uint256 setId) external view returns (
        bytes32 nameHash_,
        uint256 maxPerSet_,
        uint256 priceWei_,
        address creator_,
        uint256 mintedFromSet_,
        bool saleOpen_,
        uint256 createdAtBlock_
    ) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        return (s.nameHash, s.maxPerSet, s.priceWei, s.creator, s.mintedFromSet, s.saleOpen, s.createdAtBlock);
    }
    function getSetInfoExtra(uint256 setId) external view returns (
        bytes32 nameHash_,
        uint256 maxPerSet_,
        uint256 priceWei_,
        address creator_,
        uint256 mintedFromSet_,
        bool saleOpen_,
        uint256 createdAtBlock_,
        uint256 remainingSupply_,
        uint256 snapshotCount_
    ) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        uint256 rem = s.maxPerSet > s.mintedFromSet ? s.maxPerSet - s.mintedFromSet : 0;
        return (s.nameHash, s.maxPerSet, s.priceWei, s.creator, s.mintedFromSet, s.saleOpen, s.createdAtBlock, rem, _setSnapshotIds[setId].length);
    }
    function getSetIdsPaginated(uint256 page, uint256 pageSize) external view returns (uint256[] memory) {
        uint256 len = _setIds.length;
        if (page * pageSize >= len) return new uint256[](0);
        uint256 start = page * pageSize;
        uint256 end = start + pageSize;
        if (end > len) end = len;
        uint256 n = end - start;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _setIds[start + i];
        return out;
    }
    function getSetSnapshotIdsPaginated(uint256 setId, uint256 page, uint256 pageSize) external view returns (uint256[] memory) {
        uint256[] storage ids = _setSnapshotIds[setId];
        uint256 len = ids.length;
        if (page * pageSize >= len) return new uint256[](0);
        uint256 start = page * pageSize;
        uint256 end = start + pageSize;
        if (end > len) end = len;
        uint256 n = end - start;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = ids[start + i];
        return out;
    }
    function getSetSnapshotStructById(uint256 snapshotId) external view returns (SetSnapshot memory) {
        return setSnapshots[snapshotId];
    }
    function getSetSnapshotStructBySetAndIndex(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        uint256 sid = _setSnapshotIds[setId][index];
        return setSnapshots[sid];
    }
    function getSetIdsRange(uint256 from, uint256 to) external view returns (uint256[] memory) {
        uint256 len = _setIds.length;
        if (from >= len) return new uint256[](0);
        if (to > len) to = len;
        if (to <= from) return new uint256[](0);
        uint256 n = to - from;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _setIds[from + i];
        return out;
    }
    function getSetSnapshotIdsRange(uint256 setId, uint256 from, uint256 to) external view returns (uint256[] memory) {
        uint256[] storage ids = _setSnapshotIds[setId];
        uint256 len = ids.length;
        if (from >= len) return new uint256[](0);
        if (to > len) to = len;
        if (to <= from) return new uint256[](0);
        uint256 n = to - from;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = ids[from + i];
        return out;
    }
    function getSetSnapshotStructBySnapshotId(uint256 snapshotId) external view returns (SetSnapshot memory) {
        return setSnapshots[snapshotId];
    }
    function getSetSnapshotStructBySetIdAndIndex(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }
    function getSetSnapshotStructBySetIdAndSnapshotIndex(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }
    function getSetSnapshotStructBySnapshotId(uint256 snapshotId) external view returns (SetSnapshot memory) {
        return setSnapshots[snapshotId];
    }
    function getSetSnapshotStructBySetAndSnapshotIndex(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }
    function getSetSnapshotStructBySetAndIndex(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }
    function getSetSnapshotStructBySnapshotIdValue(uint256 snapshotId) external view returns (SetSnapshot memory) {
        return setSnapshots[snapshotId];
    }
    function getSetSnapshotStructBySetIdAndIndexValue(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }
    function getSetSnapshotStructBySetIdAndSnapshotIndexValue(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }
    function getSetSnapshotStructBySetAndSnapshotIndexValue(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }
    function getSetSnapshotStructBySetAndIndexValue(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }
    function getSetSnapshotStructBySnapshotIdValue(uint256 snapshotId) external view returns (SetSnapshot memory) {
        return setSnapshots[snapshotId];
    }
    function getSetSnapshotStructBySetIdAndIndexValue(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }
    function getSetSnapshotStructBySetIdAndSnapshotIndexValue(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }
    function getSetSnapshotStructBySetAndSnapshotIndexValue(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }
    function getSetSnapshotStructBySetAndIndexValue(uint256 setId, uint256 index) external view returns (SetSnapshot memory) {
        if (index >= _setSnapshotIds[setId].length) revert PMU_InvalidIndex();
        return setSnapshots[_setSnapshotIds[setId][index]];
    }

    function getFrontendConfig() external view returns (
        address nft_,
        uint256 nextTokenId_,
        uint256 setCounter_,
        uint256 feeBps_,
        bool platformPaused_,
        uint256 deployBlock_,
        address treasury_,
        address vault_,
        address launchpadWallet_
    ) {
        return (pokeBroNft, nextTokenId, setCounter, feeBps, platformPaused, deployBlock, treasury, vault, launchpadWallet);
    }

    function getSetListForFrontend(uint256 fromIndex, uint256 toIndex) external view returns (uint256[] memory ids, uint256[] memory prices, bool[] memory saleOpen) {
        uint256 len = _setIds.length;
        if (fromIndex >= len) return (new uint256[](0), new uint256[](0), new bool[](0));
        if (toIndex > len) toIndex = len;
        if (toIndex <= fromIndex) return (new uint256[](0), new uint256[](0), new bool[](0));
        uint256 n = toIndex - fromIndex;
        ids = new uint256[](n);
        prices = new uint256[](n);
        saleOpen = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 sid = _setIds[fromIndex + i];
            ids[i] = sid;
            prices[i] = sets[sid].priceWei;
            saleOpen[i] = sets[sid].saleOpen;
        }
        return (ids, prices, saleOpen);
    }

    function getSetDetailsForFrontend(uint256 setId) external view returns (
        bytes32 nameHash_,
        uint256 maxPerSet_,
        uint256 priceWei_,
        address creator_,
        uint256 mintedFromSet_,
        bool saleOpen_,
        uint256 remaining_
    ) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        uint256 rem = s.maxPerSet > s.mintedFromSet ? s.maxPerSet - s.mintedFromSet : 0;
        return (s.nameHash, s.maxPerSet, s.priceWei, s.creator, s.mintedFromSet, s.saleOpen, rem);
    }

    function computeMintCost(uint256 setId, uint256 count) external view returns (uint256 totalWei, uint256 feeWei, uint256 toCreator, uint256 toLaunchpad) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        totalWei = sets[setId].priceWei * count;
        feeWei = (totalWei * feeBps) / PMU_BPS_BASE;
        toCreator = (totalWei - feeWei) / 2;
        toLaunchpad = totalWei - feeWei - toCreator;
        return (totalWei, feeWei, toCreator, toLaunchpad);
    }

    function getSetIdsPaginatedV2(uint256 page, uint256 pageSize) external view returns (uint256[] memory) {
        return getSetIdsPaginated(page, pageSize);
    }

    function getSetSnapshotIdsPaginatedV2(uint256 setId, uint256 page, uint256 pageSize) external view returns (uint256[] memory) {
        return getSetSnapshotIdsPaginated(setId, page, pageSize);
    }

    function totalSetCount() external view returns (uint256) {
        return _setIds.length;
    }

    function totalSnapshotCount() external view returns (uint256) {
        return snapshotSequence;
    }

    function isPokeBroSet() external view returns (bool) {
        return pokeBroNft != address(0);
    }

    function getSetPriceForCount(uint256 setId, uint256 count) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        return sets[setId].priceWei * count;
    }

    function getSetFeeForTotal(uint256 totalWei) external view returns (uint256) {
        return (totalWei * feeBps) / PMU_BPS_BASE;
    }

    function getSetCreatorShare(uint256 totalWei, uint256 feeWei) external pure returns (uint256) {
        return (totalWei - feeWei) / 2;
    }

    function getSetLaunchpadShare(uint256 totalWei, uint256 feeWei, uint256 creatorShare) external pure returns (uint256) {
        return totalWei - feeWei - creatorShare;
    }

    function getSetRemainingSupply(uint256 setId) external view returns (uint256) {
        if (setId == 0 || setId > setCounter) revert PMU_SetNotFound();
        SetInfo storage s = sets[setId];
        return s.maxPerSet > s.mintedFromSet ? s.maxPerSet - s.mintedFromSet : 0;
    }

    function getGlobalRemainingSupply() external view returns (uint256) {
        return nextTokenId >= PMU_POKEBRO_CAP ? 0 : PMU_POKEBRO_CAP - nextTokenId;
    }

    function getSetIdsAll() external view returns (uint256[] memory) {
        return _setIds;
    }

    function getSetSnapshotIdsAll(uint256 setId) external view returns (uint256[] memory) {
        return _setSnapshotIds[setId];
