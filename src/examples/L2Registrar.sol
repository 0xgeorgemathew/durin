// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { StringUtils } from "@ensdomains/ens-contracts/utils/StringUtils.sol";

import { IL2Registry } from "../interfaces/IL2Registry.sol";

/// @dev This is an example registrar contract that is mean to be modified.
contract L2Registrar {
    using StringUtils for string;

    /// @notice Emitted when a new name is registered
    /// @param label The registered label (e.g. "name" in "name.eth")
    /// @param owner The owner of the newly registered name
    event NameRegistered(string indexed label, address indexed owner);

    /// @notice Emitted when a primary name is updated
    /// @param owner The address whose primary name was updated
    /// @param label The new primary name label
    event PrimaryNameSet(address indexed owner, string label);

    /// @notice Reference to the target registry contract
    IL2Registry public immutable registry;

    /// @notice The chainId for the current chain
    uint256 public chainId;

    /// @notice The coinType for the current chain (ENSIP-11)
    uint256 public immutable coinType;

    /// @notice Mapping from address to their primary name label (for reverse resolution)
    mapping(address => string) public primaryName;

    /// @notice Initializes the registrar with a registry contract
    /// @param _registry Address of the L2Registry contract
    constructor(
        address _registry
    ) {
        // Save the chainId in memory (can only access this in assembly)
        assembly {
            sstore(chainId.slot, chainid())
        }

        // Calculate the coinType for the current chain according to ENSIP-11
        coinType = (0x80000000 | chainId) >> 0;

        // Save the registry address
        registry = IL2Registry(_registry);
    }

    /// @notice Registers a new name
    /// @param label The label to register (e.g. "name" for "name.eth")
    /// @param owner The address that will own the name
    function register(
        string calldata label,
        address owner
    ) external {
        bytes32 node = _labelToNode(label);
        bytes memory addr = abi.encodePacked(owner); // Convert address to bytes

        // Set the forward address for the current chain. This is needed for reverse resolution.
        // E.g. if this contract is deployed to Base, set an address for chainId 8453 which is
        // coinType 2147492101 according to ENSIP-11.
        registry.setAddr(node, coinType, addr);

        // Set the forward address for mainnet ETH (coinType 60) for easier debugging.
        registry.setAddr(node, 60, addr);

        // Register the name in the L2 registry
        registry.createSubnode(registry.baseNode(), label, owner, new bytes[](0));

        // Auto-set primary name for reverse resolution (address -> label)
        // Only set if user doesn't already have a primary name
        if (bytes(primaryName[owner]).length == 0) {
            primaryName[owner] = label;
            emit PrimaryNameSet(owner, label);
        }

        emit NameRegistered(label, owner);
    }

    /// @notice Gets the primary name label for an address (reverse resolution)
    /// @param addr The address to look up
    /// @return The primary name label (e.g. "player1"), or empty string if none
    function getName(
        address addr
    ) external view returns (string memory) {
        return primaryName[addr];
    }

    /// @notice Gets the full ENS name for an address (e.g. "player1.grid.eth")
    /// @param addr The address to look up
    /// @return The full name, or empty string if none
    function getFullName(
        address addr
    ) external view returns (string memory) {
        string memory label = primaryName[addr];
        if (bytes(label).length == 0) {
            return "";
        }
        bytes32 node = _labelToNodeMemory(label);
        bytes memory dnsName = registry.names(node);
        return registry.decodeName(dnsName);
    }

    /// @notice Allows a user to change their primary name
    /// @dev Caller must own the name they're setting as primary
    /// @param label The label to set as primary name
    function setPrimaryName(
        string calldata label
    ) external {
        bytes32 node = _labelToNode(label);
        uint256 tokenId = uint256(node);

        // Verify caller owns this name
        require(registry.ownerOf(tokenId) == msg.sender, "Not owner of name");

        primaryName[msg.sender] = label;
        emit PrimaryNameSet(msg.sender, label);
    }

    /// @notice Checks if a given label is available for registration
    /// @dev Uses try-catch to handle the ERC721NonexistentToken error
    /// @param label The label to check availability for
    /// @return available True if the label can be registered, false if already taken
    function available(
        string calldata label
    ) external view returns (bool) {
        bytes32 node = _labelToNode(label);
        uint256 tokenId = uint256(node);

        try registry.ownerOf(tokenId) {
            return false;
        } catch {
            if (label.strlen() >= 3) {
                return true;
            }
            return false;
        }
    }

    function _labelToNode(
        string calldata label
    ) private view returns (bytes32) {
        return registry.makeNode(registry.baseNode(), label);
    }

    function _labelToNodeMemory(
        string memory label
    ) private view returns (bytes32) {
        return registry.makeNode(registry.baseNode(), label);
    }
}

