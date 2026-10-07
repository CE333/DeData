// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDeDataProtocol {
    function requestSummary(uint256 requestId)
        external
        view
        returns (address buyer, uint256 datasetId, bool completed);
}

/// @title DeDataProvenance
/// @author Hossein Amirbeik (SIMURIAX)
/// @notice Soulbound receipts (ERC-721, ERC-5192) binding a trained model to the completed
///         DeDataProtocol requests, and therefore the datasets, it was trained on.
contract DeDataProvenance {
    struct Receipt {
        address trainer;
        uint64 mintedAt;
        bytes32 modelHash;
    }

    string public constant name = "DeData Model Provenance";
    string public constant symbol = "DDPROV";
    uint256 public constant MAX_LINEAGE = 50;

    IDeDataProtocol public immutable protocol;

    uint256 public totalSupply;

    mapping(uint256 => Receipt) private _receipts;
    mapping(uint256 => uint256[]) private _requestLineage;
    mapping(uint256 => uint256[]) private _datasetLineage;
    mapping(uint256 => string) private _tokenURIs;
    mapping(address => uint256) private _balances;
    mapping(bytes32 => uint256) public tokenOfModel;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Locked(uint256 tokenId);
    event ReceiptMinted(
        uint256 indexed tokenId,
        address indexed trainer,
        bytes32 indexed modelHash,
        uint256[] requestIds,
        uint256[] datasetIds
    );

    error ZeroAddress();
    error InvalidProtocol();
    error InvalidModelHash();
    error ModelAlreadyRegistered();
    error InvalidLineageLength();
    error UnsortedRequestIds();
    error RequestNotEligible(uint256 requestId);
    error NonexistentToken();
    error Soulbound();

    constructor(address protocol_) {
        if (protocol_.code.length == 0) revert InvalidProtocol();
        protocol = IDeDataProtocol(protocol_);
    }

    /// @notice Mints a provenance receipt for a model trained on the caller's completed requests.
    /// @param modelHash  Hash of the model weights or model card. Each model can be registered once.
    /// @param requestIds Strictly increasing IDs of completed requests owned by the caller.
    /// @param uri        Token metadata URI.
    function mint(bytes32 modelHash, uint256[] calldata requestIds, string calldata uri)
        external
        returns (uint256 tokenId)
    {
        if (modelHash == bytes32(0)) revert InvalidModelHash();
        if (tokenOfModel[modelHash] != 0) revert ModelAlreadyRegistered();
        uint256 length = requestIds.length;
        if (length == 0 || length > MAX_LINEAGE) revert InvalidLineageLength();

        tokenId = ++totalSupply;
        uint256[] storage datasetIds = _datasetLineage[tokenId];

        uint256 previous;
        for (uint256 i; i < length; ++i) {
            uint256 requestId = requestIds[i];
            if (requestId <= previous) revert UnsortedRequestIds();
            previous = requestId;

            (address buyer, uint256 datasetId, bool completed) = protocol.requestSummary(requestId);
            if (!completed || buyer != msg.sender) revert RequestNotEligible(requestId);
            datasetIds.push(datasetId);
        }

        _requestLineage[tokenId] = requestIds;
        _receipts[tokenId] = Receipt({trainer: msg.sender, mintedAt: uint64(block.timestamp), modelHash: modelHash});
        _tokenURIs[tokenId] = uri;
        _balances[msg.sender] += 1;
        tokenOfModel[modelHash] = tokenId;

        emit Transfer(address(0), msg.sender, tokenId);
        emit Locked(tokenId);
        emit ReceiptMinted(tokenId, msg.sender, modelHash, requestIds, datasetIds);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function receipt(uint256 tokenId) external view returns (Receipt memory) {
        _requireOwned(tokenId);
        return _receipts[tokenId];
    }

    function lineage(uint256 tokenId)
        external
        view
        returns (uint256[] memory requestIds, uint256[] memory datasetIds)
    {
        _requireOwned(tokenId);
        return (_requestLineage[tokenId], _datasetLineage[tokenId]);
    }

    /*//////////////////////////////////////////////////////////////
                           ERC-721 / ERC-5192
    //////////////////////////////////////////////////////////////*/

    function balanceOf(address account) external view returns (uint256) {
        if (account == address(0)) revert ZeroAddress();
        return _balances[account];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _requireOwned(tokenId);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        _requireOwned(tokenId);
        return _tokenURIs[tokenId];
    }

    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC-165
            || interfaceId == 0x80ac58cd // ERC-721
            || interfaceId == 0x5b5e139f // ERC-721 Metadata
            || interfaceId == 0xb45a3c0e; // ERC-5192
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        _requireOwned(tokenId);
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) external pure {
        revert Soulbound();
    }

    function transferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert Soulbound();
    }

    function _requireOwned(uint256 tokenId) private view returns (address trainer) {
        trainer = _receipts[tokenId].trainer;
        if (trainer == address(0)) revert NonexistentToken();
    }
}
