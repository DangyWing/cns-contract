// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ECDSA} from "solady/utils/ECDSA.sol";
import {IDelegationRegistry} from "./interfaces/IDelegationRegistry.sol";
import {LibLinearVRGDA} from "./lib/LibLinearVRGDA.sol";
import {LibString} from "./lib/LibString.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {toDaysWadUnsafe, wadLn} from "solmate/src/utils/SignedWadMath.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {
    ERC721,
    ERC721Enumerable,
    IERC721,
    IERC721Enumerable
} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

/*
          _____                    _____                    _____          
         /\    \                  /\    \                  /\    \         
        /::\    \                /::\____\                /::\    \        
       /::::\    \              /::::|   |               /::::\    \       
      /::::::\    \            /:::::|   |              /::::::\    \      
     /:::/\:::\    \          /::::::|   |             /:::/\:::\    \     
    /:::/  \:::\    \        /:::/|::|   |            /:::/__\:::\    \    
   /:::/    \:::\    \      /:::/ |::|   |            \:::\   \:::\    \   
  /:::/    / \:::\    \    /:::/  |::|   | _____    ___\:::\   \:::\    \  
 /:::/    /   \:::\    \  /:::/   |::|   |/\    \  /\   \:::\   \:::\    \ 
/:::/____/     \:::\____\/:: /    |::|   /::\____\/::\   \:::\   \:::\____\
\:::\    \      \::/    /\::/    /|::|  /:::/    /\:::\   \:::\   \::/    /
 \:::\    \      \/____/  \/____/ |::| /:::/    /  \:::\   \:::\   \/____/ 
  \:::\    \                      |::|/:::/    /    \:::\   \:::\    \     
   \:::\    \                     |::::::/    /      \:::\   \:::\____\    
    \:::\    \                    |:::::/    /        \:::\  /:::/    /    
     \:::\    \                   |::::/    /          \:::\/:::/    /     
      \:::\    \                  /:::/    /            \::::::/    /      
       \:::\____\                /:::/    /              \::::/    /       
        \::/    /                \::/    /                \::/    /        
         \/____/                  \/____/                  \/____/         
                                                                           */

interface Turnstile {
    function register(address) external returns (uint256);
}

contract CantoNameService is ERC721, ERC2981, ERC721Enumerable, Owned(msg.sender), ReentrancyGuard {
    IDelegationRegistry public immutable registry;
    // Turnstile turnstile = Turnstile(0xEcf044C5B4b867CFda001101c617eCd347095B44);

    uint256 immutable GRACE_PERIOD = 30 days;

    string public baseURI;
    string public contractURI;
    string public expiredURI;
    address public _signerAddress;
    ///@dev 0 = closed, 1 = open
    uint256 public status = 0;

    constructor(address _registryAddress, address _signerAddress_) ERC721("Canto Name Service", "CNS") {
        registry = IDelegationRegistry(_registryAddress);
        _signerAddress = _signerAddress_;
        // turnstile.register(tx.origin);
    }

    mapping(address => bool) public allowlistClaimed;

    /// @notice Tracks counts for each name length via uint256 length
    /// @dev this is zero indexed but the length passed to tokenCounts
    /// @dev should be the length you are interested in
    mapping(uint256 => uint256) public tokenCounts;

    /// @dev All values in VRGDA are scaled to 1e18 except startTime
    struct VRGDAConstants {
        int256 targetPrice;
        int256 priceDecayPercent;
        int256 decayConstant;
        int256 perTimeUnit;
        int256 startTime;
    }

    /// @dev lookup from tokenId to current Primary address
    mapping(uint256 => address) public currentPrimary;
    mapping(uint256 => uint256) public expiry;
    mapping(uint256 => string) public tokenToName;

    /// @dev lookup Primary tokenId from address
    mapping(address => uint256) public primaryName;

    /// @dev VRGDA data storage
    mapping(uint256 => VRGDAConstants) public vrgdaData;

    /*//////////////////////////////////////////////////////////////
                        NAME REGISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Registers name to an address
    /// @param name name to register
    /// @param term count of years to register name for
    /// @param signature allowing registration

    function registerName(string calldata name, uint256 term, bytes calldata signature) external payable nonReentrant {
        if (status != 1) revert InvalidStatus();
        if (term < 1) revert InvalidTerm();

        uint256 _length = _stringLength(name);

        uint256 price = priceNameLength(_length);
        if (msg.value < price * term) revert InvalidPayment();

        if (!_verifySignature(name, signature)) revert InvalidSig();

        _registerName(name, term, _length, price);

        SafeTransferLib.safeTransferETH(msg.sender, msg.value - (price * term));
    }

    /// @notice Registers name that is on the allowlist
    /// @param name name to register
    /// @param signature allowing registration

    function registerNameOnAllowlist(string calldata name, bytes calldata signature) external payable nonReentrant {
        if (status != 1) revert InvalidStatus();
        if (allowlistClaimed[msg.sender]) revert AlreadyClaimed();

        uint256 _length = _stringLength(name);

        uint256 price = priceNameLength(_length) / 2;
        if (msg.value < (price)) revert InvalidPayment();

        if (!_verifySignature(name, signature)) revert InvalidSig();

        allowlistClaimed[msg.sender] = true;

        _registerName(name, 1, _length, price);

        SafeTransferLib.safeTransferETH(msg.sender, msg.value - (price));
    }

    /*//////////////////////////////////////////////////////////////
                        RENEWALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Renews name registration for a given term
    /// @param tokenId renew registration for this tokenId
    /// @param term count of years to extend the registration

    function renewName(uint256 tokenId, uint256 term) external payable nonReentrant {
        if (term < 1) revert InvalidTerm();

        uint256 _length = _stringLength(tokenToName[tokenId]);
        uint256 price = priceNameLength(_length);

        if (msg.value < price * term) revert InvalidPayment();

        uint256 oldExpiry = expiry[tokenId];

        if (oldExpiry + GRACE_PERIOD < block.timestamp) revert TooLate();

        uint256 _newExpiry = oldExpiry + uint256(term * 365 days);

        if (isNameExpired(tokenId)) {
            _newExpiry = uint256(block.timestamp) + (term * 365 days);
        }

        expiry[tokenId] = _newExpiry;

        SafeTransferLib.safeTransferETH(msg.sender, msg.value - (price * term));

        emit Renew(ownerOf(tokenId), tokenId, _newExpiry);
    }

    /*//////////////////////////////////////////////////////////////
                        PRIMARY NAME
    //////////////////////////////////////////////////////////////*/

    /// @notice Clears the primary name of the sender
    /// @dev this is external so that accounts can clear their own primary names

    function clearPrimaryName() external {
        _clearPrimary(msg.sender);
    }

    /// @notice Return the primary name of a given address
    /// @param _address return the primary name of this address
    /// @dev this call is preferred over calling primaryName directly as
    /// @dev primaryName does not have a check for name expiration

    function getPrimary(address _address) external view returns (string memory) {
        uint256 tokenId = primaryName[_address];

        if (tokenId == 0) revert NoPrimaryName();
        if (isNameExpired(tokenId)) revert NameExpired();

        return tokenToName[tokenId];
    }

    /// @notice Sets the primary name of a given tokenId
    /// @param tokenId tokenId to set the primary address
    /// @param _vault optional delegate.cash vault address
    /// @dev use 0x0 for _vault if not using a delegate.cash vault

    function setPrimaryName(uint256 tokenId, address _vault) external {
        if (!isAddressRightsHolder(msg.sender, tokenId, _vault)) revert NotRightsHolder();

        primaryName[msg.sender] = tokenId;
        currentPrimary[tokenId] = msg.sender;

        emit Primary(msg.sender, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets base URI for token metadata
    /// @param _newBaseURI new base URI

    function setBaseURI(string calldata _newBaseURI) external onlyOwner {
        baseURI = _newBaseURI;
    }

    /// @notice Sets contractURI
    /// @param _contractURI new contractURI

    function setContractURI(string memory _contractURI) external onlyOwner {
        contractURI = _contractURI;
    }

    /// @notice Sets expired URI for token metadata
    /// @param _newExpiredURI new expired URI

    function setExpiredURI(string calldata _newExpiredURI) external onlyOwner {
        expiredURI = _newExpiredURI;
    }

    /// @notice Sets the default royalty fee
    /// @param receiver address to receive the royalty fee
    /// @param royaltyFeeInBips royalty fee in bips e.g. 4200 = 42%

    function setRoyaltyInfo(address receiver, uint96 royaltyFeeInBips) external onlyOwner {
        _setDefaultRoyalty(receiver, royaltyFeeInBips);
    }

    /// @notice Sets signerAddress for verifying signatures
    /// @param newSignerAddress new signer address

    function setSignerAddress(address newSignerAddress) external onlyOwner {
        _signerAddress = newSignerAddress;
    }

    /// @notice Sets registration status
    /// @param newStatus new status

    function setStatus(uint256 newStatus) external onlyOwner {
        status = newStatus;
    }

    /*//////////////////////////////////////////////////////////////
                        HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks if an address is the rights holder of a given tokenId
    /// @param _address address to check
    /// @param tokenId tokenId to check
    /// @param _vault optional delegate.cash vault address
    /// @dev use 0x0 for _vault if not using a delegate.cash vault

    function isAddressRightsHolder(address _address, uint256 tokenId, address _vault) public view returns (bool) {
        if (!_exists(tokenId)) revert InvalidToken();

        if (isNameExpired(tokenId)) {
            return false;
        }

        address requester = _address;

        if (_vault != address(0x0)) {
            bool isDelegateValid = registry.checkDelegateForToken(_address, _vault, address(this), tokenId);

            if (!isDelegateValid) revert NotRightsHolder();

            requester = _vault;
        }

        return ownerOf(tokenId) == requester;
    }

    /// @notice checks if a name is available for reservation
    /// @param tokenId tokenId to check
    /// @return bool true if name is available

    function isNameAvailable(uint256 tokenId) public view returns (bool) {
        return expiry[tokenId] < GRACE_PERIOD + block.timestamp;
    }

    /// @notice Checks if name registration has expired
    /// @param tokenId tokenId to check

    function isNameExpired(uint256 tokenId) public view returns (bool) {
        return expiry[tokenId] < block.timestamp;
    }

    /// @notice Returns the address of the current rights owner of a given tokenId
    /// @param tokenId tokenId to check
    /// @param _vault optional delegate.cash vault address
    /// @dev this includes the vault address if applicable
    /// @dev this is gas intensive so should only be used from front ends if possible

    function nameRightsHolders(uint256 tokenId, address _vault) external view returns (address[] memory) {
        if (!_exists(tokenId)) revert InvalidToken();

        if (isNameExpired(tokenId)) {
            return new address[](0);
        } else if (_vault == address(0x0)) {
            address[] memory _ownerAddress = new address[](1);
            _ownerAddress[0] = ownerOf(tokenId);
            return _ownerAddress;
        }

        address[] memory delegatedAddresses = registry.getDelegatesForToken(_vault, address(this), tokenId);

        address[] memory allRightsHolders = new address[](delegatedAddresses.length + 1);

        if (delegatedAddresses.length > 1) {
            allRightsHolders[0] = ownerOf(tokenId);

            for (uint256 i = 1; i < allRightsHolders.length; ++i) {
                allRightsHolders[i] = delegatedAddresses[i - 1];
            }

            return allRightsHolders;
        } else {
            address[] memory _addresses = new address[](1);
            _addresses[0] = ownerOf(tokenId);
            return _addresses;
        }
    }

    /// @notice Converts string name to uint256 tokenId
    /// @param name Name to convert
    /// @dev there is a JS solution to converting a name to a token Id
    /// @dev consider using the JS solution to avoid an RPC call

    function nameToId(string calldata name) public pure returns (uint256) {
        string memory _lowerName = LibString.lower(name);
        return (uint256(keccak256(abi.encodePacked(_lowerName))));
    }

    /// @notice Gets the owner of the specified token
    /// @param tokenId ID of the token to query the owner of
    /// @dev Name is unowned if expired

    function ownerOf(uint256 tokenId) public view override(IERC721, ERC721) returns (address) {
        if (expiry[tokenId] < block.timestamp) revert NameExpired();
        return super.ownerOf(tokenId);
    }

    /// @notice Returns price of name based on string length
    /// @param name Name to price
    /// @dev price is for one term aka 1 year

    function priceName(string calldata name) public view returns (uint256) {
        uint256 _length = _stringLength(name);
        return priceNameLength(_length);
    }

    /// @notice Returns price of name based on string length
    /// @param length Length of the name
    /// @dev price is for one term
    /// @dev _length parameter directly calls corresponding VRGDA via getVRGDAPrice()

    function priceNameLength(uint256 length) public view returns (uint256) {
        if (length == 0) revert InvalidLength();
        if (length > 0 && length < 6) {
            return _getVRGDAPrice(length);
        } else {
            return _getVRGDAPrice(6);
        }
    }

    /// @notice Returns token metadata URI
    /// @param tokenId tokenId to get URI for

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) revert InvalidToken();

        string memory uri = baseURI;

        if (isNameExpired(tokenId)) {
            uri = expiredURI;
        }

        return bytes(uri).length > 0 ? string(abi.encodePacked(uri, LibString.toString(tokenId))) : "";
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Clears the primary name of a given address
    /// @param _address address to clear the primary name of

    function _clearPrimary(address _address) internal {
        uint256 _tokenId = primaryName[_address];

        delete primaryName[_address];
        currentPrimary[_tokenId] = address(0x0);

        emit ClearPrimary(_address, _tokenId);
    }

    /// @notice Returns price of name based on string length
    /// @param _length length of string to check
    /// @dev length offset -1 in the function because vrgdaData index starts at 0

    function _getVRGDAPrice(uint256 _length) internal view returns (uint256) {
        uint256 _index = _length - 1;

        int256 _daysDiff = toDaysWadUnsafe(uint256(block.timestamp - uint256(vrgdaData[_index].startTime)));

        uint256 price = LibLinearVRGDA.getVRGDAPrice(
            vrgdaData[_index].targetPrice,
            vrgdaData[_index].priceDecayPercent,
            vrgdaData[_index].perTimeUnit,
            _daysDiff,
            tokenCounts[_length]
        );
        return price;
    }

    /// @notice Increments the proper counters based on string length (accurate counts through 5)
    /// @param _length length of string to increment

    function _incrementCounts(uint256 _length) internal {
        if (_length > 5) {
            ++tokenCounts[6];
        } else {
            ++tokenCounts[_length];
        }
    }

    /// @notice Registers name
    /// @param _name name to register
    /// @param _term count of years to register _name for
    /// @param _length length of _name
    /// @param _price price of _name *only used for event*

    function _registerName(string calldata _name, uint256 _term, uint256 _length, uint256 _price) internal {
        uint256 _tokenId = nameToId(_name);
        if (!isNameAvailable(_tokenId)) revert TokenUnavailable();

        if (_exists(_tokenId)) {
            _burn(_tokenId);
        }

        _incrementCounts(_length);

        uint256 _expiry = uint256(block.timestamp) + (_term * 365 days);

        tokenToName[_tokenId] = _name;
        expiry[_tokenId] = _expiry;

        _safeMint(msg.sender, _tokenId);

        emit Register(ownerOf(_tokenId), _tokenId, _expiry, _price);
    }

    /// @notice Return string length, properly counts all Unicode characters
    /// @param _string String to check
    /// @dev this function only counts up to 6 characters

    function _stringLength(string memory _string) internal pure returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            if mload(_string) {
                mstore(0x00, div(not(0), 255))
                mstore(0x20, 0x0202020202020202020202020202020202020202020202020303030304040506)
                let o := add(_string, 0x20)
                let end := add(o, mload(_string))
                for { result := 1 } lt(result, 6) { result := add(result, 1) } {
                    o := add(o, byte(0, mload(shr(250, mload(o)))))
                    if iszero(lt(o, end)) { break }
                }
            }
        }
        return result;
    }

    /// @notice Verifies the signature vs. the signer address
    /// @param _name Name to verify
    /// @param signature Signature to verify

    function _verifySignature(string calldata _name, bytes calldata signature) internal view returns (bool) {
        bytes32 hash = keccak256(abi.encodePacked(msg.sender, _name));
        bytes32 ethSignedMessageHash = ECDSA.toEthSignedMessageHash(hash);
        return _signerAddress == ECDSA.recover(ethSignedMessageHash, signature);
    }

    /*//////////////////////////////////////////////////////////////
                        VRGDA MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets up VRGDA constants for a specific length
    /// @param lengthToSetup Length of name to setup VRGDA for
    /// @param targetPrice Target price for VRGDA (scaled to 1e18)
    /// @param priceDecayPercent Price decay percent for VRGDA (must be < 1e18)
    /// @param perTimeUnit Time unit for VRGDA (scaled to 1e18)

    function setupSingleVRGDA(uint256 lengthToSetup, int256 targetPrice, int256 priceDecayPercent, int256 perTimeUnit)
        external
        onlyOwner
    {
        if (priceDecayPercent >= 1e18) revert PercentTooHigh();
        uint256 _index = lengthToSetup - 1;

        vrgdaData[_index].targetPrice = targetPrice;
        vrgdaData[_index].priceDecayPercent = priceDecayPercent;
        vrgdaData[_index].decayConstant = wadLn(1e18 - priceDecayPercent);
        vrgdaData[_index].perTimeUnit = perTimeUnit;
        vrgdaData[_index].startTime = int256(block.timestamp);

        emit SetupVRGDA(lengthToSetup, targetPrice, priceDecayPercent, perTimeUnit);
    }

    /// @notice Sets up VRGDA constants for names of length 1-6
    /// @param targetPrice Target price for VRGDA (scaled to 1e18)
    /// @param priceDecayPercent Price decay percent for VRGDA (should be < 1e18)
    /// @param perTimeUnit Time unit for VRGDA (scaled to 1e18)
    /// @param vrgdasToSetup Number of VRGDA to setup (scaled to 1e18)
    /// @dev vrgdaData is 0 indexed so length 1 is at index 0

    function setupVRGDAs(
        int256[] calldata targetPrice,
        int256[] calldata priceDecayPercent,
        int256[] calldata perTimeUnit,
        uint256 vrgdasToSetup
    ) external onlyOwner {
        if (
            targetPrice.length != vrgdasToSetup || priceDecayPercent.length != vrgdasToSetup
                || perTimeUnit.length != vrgdasToSetup
        ) revert InvalidCount();

        for (uint256 i = 0; i < vrgdasToSetup;) {
            if (priceDecayPercent[i] >= 1e18) revert PercentTooHigh();

            vrgdaData[i].targetPrice = targetPrice[i];
            vrgdaData[i].priceDecayPercent = priceDecayPercent[i];
            vrgdaData[i].decayConstant = wadLn(1e18 - priceDecayPercent[i]);
            vrgdaData[i].perTimeUnit = perTimeUnit[i];
            vrgdaData[i].startTime = int256(block.timestamp);

            emit SetupVRGDA(i + 1, targetPrice[i], priceDecayPercent[i], perTimeUnit[i]);

            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ERC721 OVERLOADS
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows for checks before token transfer
    /// @param from address of sender
    /// @param to address of recipient
    /// @param tokenId _tokenId of token that was transferred
    /// @param batchSize number of tokens being transferred

    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    /// @notice Allows for checks after token transfer
    /// @param _tokenId _tokenId of token that was transferred

    function _afterTokenTransfer(uint256 _tokenId) internal {
        _clearPrimary(currentPrimary[_tokenId]);
    }

    /// @notice Safely transfers token from one address to another
    /// @param _from address of sender
    /// @param _to address of recipient
    /// @param _tokenId _tokenId of token that was transferred

    function safeTransferFrom(address _from, address _to, uint256 _tokenId) public virtual override(ERC721, IERC721) {
        safeTransferFrom(_from, _to, _tokenId, "");
        _afterTokenTransfer(_tokenId);
    }

    /// @notice Transfers token from one address to another
    /// @param _from address of sender
    /// @param _to address of recipient
    /// @param _tokenId _tokenId of token that was transferred

    function transferFrom(address _from, address _to, uint256 _tokenId) public virtual override(ERC721, IERC721) {
        _transfer(_from, _to, _tokenId);
        _afterTokenTransfer(_tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                        ROYALTIES
    //////////////////////////////////////////////////////////////*/
    /// @notice Returns royalty info for a token
    /// @param tokenId tokenId of token
    /// @param salePrice sale price of token

    function royaltyInfo(uint256 tokenId, uint256 salePrice) public view virtual override returns (address, uint256) {
        (address receiver, uint256 royaltyAmount) = ERC2981.royaltyInfo(tokenId, salePrice);
        return (receiver, royaltyAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        PAYMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraws funds from contract

    function withdraw() public onlyOwner {
        uint256 ownerBalance = address(this).balance;
        if (ownerBalance == 0) revert NoBalance();

        (bool sent,) = msg.sender.call{value: address(this).balance}("");
        if (!sent) revert WithdrawFailed();
    }

    /*//////////////////////////////////////////////////////////////
                        ERRORS
    //////////////////////////////////////////////////////////////*/
    error AlreadyClaimed();
    error InvalidCount();
    error InvalidToken();
    error InvalidLength();
    error InvalidName();
    error InvalidPayment();
    error InvalidSig();
    error InvalidStatus();
    error InvalidTerm();
    error NameExpired();
    error NoBalance();
    error NoPrimaryName();
    error NotRightsHolder();
    error PercentTooHigh();
    error TokenUnavailable();
    error TooLate();
    error WithdrawFailed();

    /*//////////////////////////////////////////////////////////////
                        EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a name is removed as primary
    /// @param _address Address the primary name was assigned to
    /// @param id Name Id

    event ClearPrimary(address indexed _address, uint256 indexed id);

    /// @notice Emitted when a name is set as primary
    /// @param owner Address of the owner
    /// @param id Name Id

    event Primary(address indexed owner, uint256 indexed id);

    /// @notice Emitted when a name is registered
    /// @param registrant Address of the registrant
    /// @param id Token Id
    /// @param expiry Expiry timestamp
    /// @param price Price paid
    event Register(address indexed registrant, uint256 indexed id, uint256 expiry, uint256 price);

    /// @notice Emitted when a name is renewed
    /// @param owner Address of the owner
    /// @param id Name Id
    /// @param expiry Expiry timestamp
    event Renew(address indexed owner, uint256 indexed id, uint256 expiry);

    /// @notice Emitted when a VRGDA is setup
    /// @param length length of name
    /// @param targetPrice Target price for a name
    /// @param priceDecayPercent Percentage price decays per unit of time with no sales, scaled by 1e18
    /// @param perTimeUnit The number of tokens to target selling every full unit of time

    event SetupVRGDA(uint256 indexed length, int256 targetPrice, int256 priceDecayPercent, int256 perTimeUnit);

    receive() external payable {}
    fallback() external payable {}

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, ERC721Enumerable, ERC2981)
        returns (bool)
    {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }
}
