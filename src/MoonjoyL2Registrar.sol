// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StringUtils} from "@ensdomains/ens-contracts/utils/StringUtils.sol";

import {IL2Registry} from "./interfaces/IL2Registry.sol";
import {IL2Resolver} from "./interfaces/IL2Resolver.sol";

/// @title Moonjoy L2 Registrar
/// @notice Moonjoy-specific registrar for human and agent identities on Durin.
/// @dev
/// The contract keeps the ENS surface intentionally small:
/// - `label.moonjoy.eth` is the human player identity.
/// - `agent-label.moonjoy.eth` is the agent identity and resolves to the smart wallet.
/// - `moonjoy:user` links the agent name back to the human name.
/// - `moonjoy:last_match` and `moonjoy:stats` are portable public provenance pointers.
///
/// `moonjoy:match_preference` is a user-owned text record and should contain compact JSON.
/// Recommended shape:
/// `{"duration":"any"|"300"|"600","wagerUsd":"10","capitalUsd":{"min":"any"|"<usd>","max":"any"|"<usd>"}}`
///
/// This contract must be approved as a registrar on the target L2Registry.
contract MoonjoyL2Registrar {
    using StringUtils for string;

    /// @notice Prefix used for all derived agent names.
    string public constant AGENT_LABEL_PREFIX = "agent-";
    /// @notice Public text record key describing whether the name is a `user` or an `agent`.
    string public constant TEXT_KEY_TYPE = "moonjoy:type";
    /// @notice Public text record key linking an agent name back to its human ENS name.
    string public constant TEXT_KEY_USER = "moonjoy:user";
    /// @notice Public text record key pointing to the latest public match identifier or pointer.
    string public constant TEXT_KEY_LAST_MATCH = "moonjoy:last_match";
    /// @notice Public text record key pointing to public aggregate stats or replay metadata.
    string public constant TEXT_KEY_STATS = "moonjoy:stats";
    /// @notice Public text record key for automatch defaults on the human ENS name.
    string public constant TEXT_KEY_MATCH_PREFERENCE =
        "moonjoy:match_preference";
    string public constant TEXT_VALUE_USER = "user";
    string public constant TEXT_VALUE_AGENT = "agent";

    uint256 public constant MIN_LABEL_LENGTH = 3;
    uint256 public constant MAX_LABEL_LENGTH = 249;

    error InvalidOwner();
    error LabelTooShort();
    error LabelTooLong(string label);
    error ReservedAgentPrefix(string label);
    error LabelUnavailable(string label);
    error NotUserOwner(bytes32 userNode, address caller);
    error NotAgentController(bytes32 agentNode, address caller);
    error InvalidAgentBootstrapWallet();
    error UnauthorizedAgentBootstrapWallet(
        bytes32 userNode,
        address caller,
        address expected
    );

    event UserRegistered(
        string indexed label,
        bytes32 indexed userNode,
        address indexed owner
    );
    event AgentRegistered(
        string indexed userLabel,
        string indexed agentLabel,
        bytes32 indexed agentNode,
        address agentSmartWallet
    );
    event UserMatchPreferenceUpdated(
        string indexed label,
        bytes32 indexed userNode,
        string matchPreference
    );
    event AgentBootstrapWalletUpdated(
        string indexed label,
        bytes32 indexed userNode,
        address indexed agentSmartWallet
    );
    event AgentPublicPointersUpdated(
        string indexed userLabel,
        bytes32 indexed agentNode,
        string lastMatchPointer,
        string statsPointer
    );

    struct AgentIdentity {
        string userEnsName;
        string agentEnsName;
        address userAddress;
        address agentAddress;
        string lastMatchPointer;
        string statsPointer;
    }

    /// @notice Durin registry used for minting names and writing resolver records.
    IL2Registry public immutable registry;
    /// @notice ENSIP-11 coin type for the active chain. Used to set chain-specific address records.
    uint256 public immutable coinType;
    /// @notice Best-effort reverse lookup for human names. Verified on read to avoid stale ownership leaks.
    mapping(address owner => bytes32 userNode) public userNodeByAddress;
    /// @notice Best-effort reverse lookup for agent names. Verified on read to avoid stale ownership leaks.
    mapping(address owner => bytes32 agentNode) public agentNodeByAddress;
    /// @notice Human-authorized smart wallet that may self-register the derived agent ENS name.
    mapping(bytes32 userNode => address agentBootstrapWallet)
        public agentBootstrapWalletByUserNode;

    /// @param _registry Address of the deployed Durin L2Registry.
    constructor(address _registry) {
        if (_registry == address(0)) {
            revert InvalidOwner();
        }

        uint256 activeChainId;
        assembly {
            activeChainId := chainid()
        }

        registry = IL2Registry(_registry);
        coinType = (0x80000000 | activeChainId) >> 0;
    }

    /// @notice Registers a human Moonjoy name and writes the base human identity records.
    /// @dev `matchPreference` is opaque onchain text, but Moonjoy expects the compact JSON format
    /// documented in the contract header so automatch can express duration and capital ranges.
    /// @param label Human label such as `buzz`.
    /// @param matchPreference Optional compact JSON for `moonjoy:match_preference`.
    /// @return userNode Namehash of the newly minted human ENS name.
    function registerUser(
        string calldata label,
        string calldata matchPreference,
        address agentBootstrapWallet
    ) external returns (bytes32 userNode) {
        _validateUserLabel(label);

        userNode = _nodeFromLabel(label);
        if (registry.owner(userNode) != address(0)) {
            revert LabelUnavailable(label);
        }

        bytes[] memory data = _buildUserResolverCalls(
            userNode,
            msg.sender,
            matchPreference
        );

        registry.createSubnode(registry.baseNode(), label, msg.sender, data);
        userNodeByAddress[msg.sender] = userNode;
        if (agentBootstrapWallet != address(0)) {
            agentBootstrapWalletByUserNode[userNode] = agentBootstrapWallet;
            emit AgentBootstrapWalletUpdated(
                label,
                userNode,
                agentBootstrapWallet
            );
        }
        emit UserRegistered(label, userNode, msg.sender);
    }

    /// @notice Registers the derived agent name for a human user and mints it to the smart wallet.
    /// @dev The derived agent label is always `agent-{userLabel}` and cannot be chosen arbitrarily.
    /// The call is valid when either:
    /// - the human owner of `userLabel.moonjoy.eth` calls directly, or
    /// - the call originates from the pre-authorized agent bootstrap wallet stored on the user name.
    /// @param userLabel Human label such as `buzz`.
    /// @param agentSmartWallet Smart wallet that will own and resolve from the agent ENS name.
    /// @return agentNode Namehash of the derived agent ENS name.
    function registerAgent(
        string calldata userLabel,
        address agentSmartWallet
    ) external returns (bytes32 agentNode) {
        if (agentSmartWallet == address(0)) {
            revert InvalidOwner();
        }

        bytes32 userNode = _nodeFromLabel(userLabel);
        address userOwner = registry.owner(userNode);
        if (userOwner == address(0)) {
            revert NotUserOwner(userNode, msg.sender);
        }

        if (msg.sender != userOwner) {
            address expectedBootstrapWallet = agentBootstrapWalletByUserNode[
                userNode
            ];
            if (
                msg.sender != agentSmartWallet ||
                expectedBootstrapWallet == address(0) ||
                expectedBootstrapWallet != msg.sender
            ) {
                revert UnauthorizedAgentBootstrapWallet(
                    userNode,
                    msg.sender,
                    expectedBootstrapWallet
                );
            }
        }

        string memory agentLabel = _agentLabel(userLabel);
        agentNode = registry.makeNode(registry.baseNode(), agentLabel);
        if (registry.owner(agentNode) != address(0)) {
            revert LabelUnavailable(agentLabel);
        }

        bytes[] memory data = _buildAgentResolverCalls(
            agentNode,
            agentSmartWallet,
            _fullName(userLabel)
        );

        registry.createSubnode(
            registry.baseNode(),
            agentLabel,
            agentSmartWallet,
            data
        );
        agentNodeByAddress[agentSmartWallet] = agentNode;

        emit AgentRegistered(
            userLabel,
            agentLabel,
            agentNode,
            agentSmartWallet
        );
    }

    /// @notice Updates the public automatch defaults for a human Moonjoy name.
    /// @dev Recommended JSON shape:
    /// `{"duration":"any"|"300"|"600","wagerUsd":"10","capitalUsd":{"min":"any"|"<usd>","max":"any"|"<usd>"}}`
    /// `duration` supports explicit second values or `any`.
    /// `capitalUsd.min` and `capitalUsd.max` support explicit USD bounds or `any`.
    /// @param label Human label such as `buzz`.
    /// @param matchPreference Compact JSON string stored in `moonjoy:match_preference`.
    function setUserMatchPreference(
        string calldata label,
        string calldata matchPreference
    ) external {
        bytes32 userNode = _nodeFromLabel(label);
        if (registry.owner(userNode) != msg.sender) {
            revert NotUserOwner(userNode, msg.sender);
        }

        registry.setText(userNode, TEXT_KEY_MATCH_PREFERENCE, matchPreference);
        emit UserMatchPreferenceUpdated(label, userNode, matchPreference);
    }

    /// @notice Updates the smart wallet authorized to self-register the derived agent ENS name.
    /// @param label Human label such as `buzz`.
    /// @param agentSmartWallet Smart wallet that may later call `registerAgent`.
    function setAgentBootstrapWallet(
        string calldata label,
        address agentSmartWallet
    ) external {
        if (agentSmartWallet == address(0)) {
            revert InvalidAgentBootstrapWallet();
        }

        bytes32 userNode = _nodeFromLabel(label);
        if (registry.owner(userNode) != msg.sender) {
            revert NotUserOwner(userNode, msg.sender);
        }

        agentBootstrapWalletByUserNode[userNode] = agentSmartWallet;
        emit AgentBootstrapWalletUpdated(label, userNode, agentSmartWallet);
    }

    /// @notice Updates the public match provenance pointers on the agent ENS name.
    /// @param userLabel Human label such as `buzz`.
    /// @param lastMatchPointer Compact latest match id or pointer.
    /// @param statsPointer Compact stats or replay pointer.
    function setAgentPublicPointers(
        string calldata userLabel,
        string calldata lastMatchPointer,
        string calldata statsPointer
    ) external {
        bytes32 agentNode = _requireAgentController(userLabel, msg.sender);

        registry.setText(agentNode, TEXT_KEY_LAST_MATCH, lastMatchPointer);
        registry.setText(agentNode, TEXT_KEY_STATS, statsPointer);

        emit AgentPublicPointersUpdated(
            userLabel,
            agentNode,
            lastMatchPointer,
            statsPointer
        );
    }

    /// @notice Resolves the public Moonjoy identity graph for a human label.
    /// @param userLabel Human label such as `buzz`.
    /// @return profile Public identity bundle for discovery and attribution.
    function resolveAgent(
        string calldata userLabel
    ) external view returns (AgentIdentity memory profile) {
        bytes32 userNode = _nodeFromLabel(userLabel);
        string memory agentLabel = _agentLabel(userLabel);
        bytes32 agentNode = registry.makeNode(registry.baseNode(), agentLabel);

        profile = AgentIdentity({
            userEnsName: _fullName(userLabel),
            agentEnsName: _fullName(agentLabel),
            userAddress: registry.owner(userNode),
            agentAddress: registry.addr(agentNode),
            lastMatchPointer: registry.text(agentNode, TEXT_KEY_LAST_MATCH),
            statsPointer: registry.text(agentNode, TEXT_KEY_STATS)
        });
    }

    /// @notice Derives whether a user/agent identity pair is set up correctly from ENS facts.
    /// @dev This only checks onchain identity linkage. Funding, MCP approval, and strategy state
    /// belong in Moonjoy application readiness checks, not in ENS text records.
    /// @param userLabel Human label such as `buzz`.
    /// @return True when the human name exists, the derived agent name exists, the agent name
    /// resolves to its owner, and the public `moonjoy:user` backlink is correct.
    function isAgentReady(
        string calldata userLabel
    ) external view returns (bool) {
        bytes32 userNode = _nodeFromLabel(userLabel);
        string memory agentLabel = _agentLabel(userLabel);
        bytes32 agentNode = registry.makeNode(registry.baseNode(), agentLabel);
        address userOwner = registry.owner(userNode);
        address agentOwner = registry.owner(agentNode);

        if (userOwner == address(0) || agentOwner == address(0)) {
            return false;
        }

        if (registry.addr(agentNode) != agentOwner) {
            return false;
        }

        if (
            keccak256(bytes(registry.text(agentNode, TEXT_KEY_TYPE))) !=
            keccak256(bytes(TEXT_VALUE_AGENT))
        ) {
            return false;
        }

        if (
            keccak256(bytes(registry.text(agentNode, TEXT_KEY_USER))) !=
            keccak256(bytes(_fullName(userLabel)))
        ) {
            return false;
        }

        return true;
    }

    /// @notice Checks whether a human Moonjoy label is currently available.
    /// @param label Human label such as `buzz`.
    /// @return True when the label passes registrar policy and is not already minted.
    function available(string calldata label) external view returns (bool) {
        if (
            label.strlen() < MIN_LABEL_LENGTH ||
            bytes(label).length > MAX_LABEL_LENGTH ||
            _startsWith(label, AGENT_LABEL_PREFIX)
        ) {
            return false;
        }

        return registry.owner(_nodeFromLabel(label)) == address(0);
    }

    /// @notice Checks whether the derived agent label for a human label is available.
    /// @param userLabel Human label such as `buzz`.
    /// @return True when `agent-{userLabel}` is not already minted.
    function availableAgent(
        string calldata userLabel
    ) external view returns (bool) {
        string memory agentLabel = _agentLabel(userLabel);
        bytes32 agentNode = registry.makeNode(registry.baseNode(), agentLabel);
        return registry.owner(agentNode) == address(0);
    }

    /// @notice Reverse lookup for a human owner's ENS name.
    /// @dev Returns an empty string if the stored reverse pointer is stale after a transfer.
    /// @param owner Human wallet address.
    /// @return Full ENS name such as `buzz.moonjoy.eth`, or empty string.
    function getUserName(address owner) external view returns (string memory) {
        bytes32 userNode = userNodeByAddress[owner];
        if (userNode == bytes32(0) || registry.owner(userNode) != owner) {
            return "";
        }

        return registry.decodeName(registry.names(userNode));
    }

    /// @notice Reverse lookup for an agent smart wallet ENS name.
    /// @dev Returns an empty string if the stored reverse pointer is stale after a transfer or
    /// if the agent name no longer resolves to the same wallet.
    /// @param owner Agent smart wallet address.
    /// @return Full ENS name such as `agent-buzz.moonjoy.eth`, or empty string.
    function getAgentName(address owner) external view returns (string memory) {
        bytes32 agentNode = agentNodeByAddress[owner];
        if (
            agentNode == bytes32(0) ||
            registry.owner(agentNode) != owner ||
            registry.addr(agentNode) != owner
        ) {
            return "";
        }

        return registry.decodeName(registry.names(agentNode));
    }

    /// @dev Prepares the base resolver calls for a newly minted human ENS name.
    function _buildUserResolverCalls(
        bytes32 userNode,
        address owner,
        string calldata matchPreference
    ) internal view returns (bytes[] memory data) {
        uint256 extraRecordCount = bytes(matchPreference).length > 0 ? 1 : 0;
        data = new bytes[](3 + extraRecordCount);
        data[0] = _encodeDefaultAddrSet(userNode, owner);
        data[1] = _encodeChainAddrSet(userNode, owner);
        data[2] = abi.encodeCall(
            IL2Resolver.setText,
            (userNode, TEXT_KEY_TYPE, TEXT_VALUE_USER)
        );

        if (extraRecordCount == 1) {
            data[3] = abi.encodeCall(
                IL2Resolver.setText,
                (userNode, TEXT_KEY_MATCH_PREFERENCE, matchPreference)
            );
        }
    }

    /// @dev Prepares the base resolver calls for a newly minted agent ENS name.
    function _buildAgentResolverCalls(
        bytes32 agentNode,
        address agentSmartWallet,
        string memory userEnsName
    ) internal view returns (bytes[] memory data) {
        data = new bytes[](4);
        data[0] = _encodeDefaultAddrSet(agentNode, agentSmartWallet);
        data[1] = _encodeChainAddrSet(agentNode, agentSmartWallet);
        data[2] = abi.encodeCall(
            IL2Resolver.setText,
            (agentNode, TEXT_KEY_TYPE, TEXT_VALUE_AGENT)
        );
        data[3] = abi.encodeCall(
            IL2Resolver.setText,
            (agentNode, TEXT_KEY_USER, userEnsName)
        );
    }

    function _encodeDefaultAddrSet(
        bytes32 node,
        address owner
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setAddr(bytes32,address)", node, owner);
    }

    function _encodeChainAddrSet(
        bytes32 node,
        address owner
    ) internal view returns (bytes memory) {
        return
            abi.encodeWithSignature(
                "setAddr(bytes32,uint256,bytes)",
                node,
                coinType,
                abi.encodePacked(owner)
        );
    }

    /// @dev Ensures the caller is either the human ENS owner or the agent ENS owner.
    function _requireAgentController(
        string calldata userLabel,
        address caller
    ) internal view returns (bytes32 agentNode) {
        bytes32 userNode = _nodeFromLabel(userLabel);
        string memory agentLabel = _agentLabel(userLabel);
        agentNode = registry.makeNode(registry.baseNode(), agentLabel);

        address userOwner = registry.owner(userNode);
        address agentOwner = registry.owner(agentNode);

        if (caller != userOwner && caller != agentOwner) {
            revert NotAgentController(agentNode, caller);
        }
    }

    /// @dev Applies the registrar's human-label policy.
    function _validateUserLabel(string calldata label) internal pure {
        uint256 labelLength = bytes(label).length;
        if (label.strlen() < MIN_LABEL_LENGTH) {
            revert LabelTooShort();
        }
        if (labelLength > MAX_LABEL_LENGTH) {
            revert LabelTooLong(label);
        }
        if (_startsWith(label, AGENT_LABEL_PREFIX)) {
            revert ReservedAgentPrefix(label);
        }
    }

    function _startsWith(
        string memory value,
        string memory prefix
    ) internal pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory prefixBytes = bytes(prefix);

        if (prefixBytes.length > valueBytes.length) {
            return false;
        }

        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (valueBytes[i] != prefixBytes[i]) {
                return false;
            }
        }

        return true;
    }

    function _fullName(
        string memory label
    ) internal view returns (string memory) {
        string memory baseName = registry.decodeName(
            registry.names(registry.baseNode())
        );
        return string.concat(label, ".", baseName);
    }

    function _nodeFromLabel(
        string calldata label
    ) internal view returns (bytes32) {
        return registry.makeNode(registry.baseNode(), label);
    }

    /// @dev Derives the agent label from a human label.
    function _agentLabel(
        string memory userLabel
    ) internal pure returns (string memory) {
        return string.concat(AGENT_LABEL_PREFIX, userLabel);
    }
}
