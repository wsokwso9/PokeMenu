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
