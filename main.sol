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
