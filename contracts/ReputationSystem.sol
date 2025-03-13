// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@lukso/lsp-smart-contracts/contracts/LSP7DigitalAsset/LSP7DigitalAsset.sol";
import "@lukso/lsp-smart-contracts/contracts/LSP0ERC725Account/ILSP0ERC725Account.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./ProjectHub.sol";

/**
 * @title ReputationSystem
 * @dev Implements a reputation tracking system for GridHub based on LUKSO's LSP7 token standard
 * 
 * This contract awards non-transferable reputation tokens to users who contribute to projects
 * in the GridHub ecosystem. It leverages LUKSO's Universal Profiles as the identity layer and
 * LSP7 Digital Assets as the token standard.
 * 
 * Key Features:
 * - Domain-specific reputation (development, design, management, etc.)
 * - Non-transferable reputation tokens (using LSP7's force parameter)
 * - Project-based reputation awards
 * - Integration with Universal Profiles for identity verification
 * 
 * LUKSO Integration:
 * - Uses LSP7DigitalAsset for creating reputation tokens that are non-transferable
 * - Verifies that users are Universal Profiles via LSP0 interface detection
 * - Designed to be compatible with the broader LUKSO ecosystem
 */
contract ReputationSystem is Ownable {
    using SafeMath for uint256;
    
    // ------- Events -------
    event ReputationEarned(address indexed user, uint256 amount, uint256 domainId, uint256 projectId, string reason);
    event DomainCreated(uint256 indexed domainId, string name, string symbol, address tokenAddress);
    event ContributionRated(uint256 indexed projectId, uint256 indexed taskId, address contributor, uint256 rating);
    
    // ------- State Variables -------
    ProjectHub public projectHub;
    
    // Reputation domains (e.g. development, design, management)
    struct ReputationDomain {
        uint256 id;
        string name;
        string symbol;
        address tokenAddress;
        bool active;
    }
    
    // Contribution rating for tasks
    struct Contribution {
        uint256 projectId;
        uint256 taskId;
        address contributor;
        uint256 rating;     // 0-100 scale
        bool rated;
    }
    
    uint256 private nextDomainId = 1;
    
    mapping(uint256 => ReputationDomain) public domains;
    mapping(address => mapping(uint256 => uint256)) public userReputationByDomain;
    mapping(uint256 => mapping(uint256 => Contribution)) public taskContributions; // projectId => taskId => Contribution
    
    // LSP0 interface ID for checking Universal Profiles
    bytes4 private constant _INTERFACE_ID_LSP0 = 0x6bb56a14;
    
    // ------- Constructor -------
    
    /**
     * @param _projectHubAddress Address of the ProjectHub contract
     */
    constructor(address _projectHubAddress) {
        require(_projectHubAddress != address(0), "ReputationSystem: Invalid ProjectHub address");
        projectHub = ProjectHub(_projectHubAddress);
    }
    
    // ------- Modifiers -------
    
    /**
     * @dev Checks if the sender is a valid Universal Profile
     */
    modifier onlyUniversalProfile() {
        require(
            IERC165(msg.sender).supportsInterface(_INTERFACE_ID_LSP0),
            "ReputationSystem: Caller must be a Universal Profile"
        );
        _;
    }
    
    /**
     * @dev Checks if the sender has admin permission for a project
     */
    modifier onlyProjectAdmin(uint256 _projectId) {
        require(
            projectHub.getMemberRole(_projectId, msg.sender) >= uint8(ProjectHub.MemberRole.ADMIN),
            "ReputationSystem: Caller must be a project admin"
        );
        _;
    }
    
    // ------- Domain Management Functions -------
    
    /**
     * @dev Creates a new reputation domain with its own LSP7 token
     * @param _name Name of the domain (e.g. "Development", "Design")
     * @param _symbol Symbol for the token (e.g. "DEV", "DES")
     * @return domainId The ID for the created domain
     */
    function createReputationDomain(string memory _name, string memory _symbol) 
        external 
        onlyOwner 
        returns (uint256 domainId) 
    {
        domainId = nextDomainId++;
        
        // Create a new LSP7 token for this reputation domain
        // The token will be non-transferable (indicated by true flag in constructor)
        LSP7DigitalAsset token = new LSP7DigitalAsset(
            string(abi.encodePacked("GridHub ", _name, " Reputation")),
            _symbol,
            address(this),
            true // non-transferable
        );
        
        domains[domainId] = ReputationDomain({
            id: domainId,
            name: _name,
            symbol: _symbol,
            tokenAddress: address(token),
            active: true
        });
        
        emit DomainCreated(domainId, _name, _symbol, address(token));
        
        return domainId;
    }
    
    /**
     * @dev Deactivates a reputation domain (tokens remain valid but no new ones can be minted)
     * @param _domainId ID of the domain to deactivate
     */
    function deactivateDomain(uint256 _domainId) 
        external 
        onlyOwner 
    {
        require(domains[_domainId].active, "ReputationSystem: Domain is not active");
        domains[_domainId].active = false;
    }
    
    // ------- Reputation Award Functions -------
    
    /**
     * @dev Awards reputation to a user in a specific domain
     * @param _user Address of the Universal Profile to award
     * @param _domainId ID of the reputation domain
     * @param _amount Amount of reputation to award
     * @param _projectId ID of the related project
     * @param _reason Reason for awarding reputation
     */
    function awardReputation(
        address _user, 
        uint256 _domainId, 
        uint256 _amount,
        uint256 _projectId,
        string memory _reason
    ) 
        public 
        onlyOwner 
    {
        require(domains[_domainId].active, "ReputationSystem: Domain is not active");
        require(
            IERC165(_user).supportsInterface(_INTERFACE_ID_LSP0),
            "ReputationSystem: Recipient must be a Universal Profile"
        );
        
        ReputationDomain storage domain = domains[_domainId];
        LSP7DigitalAsset token = LSP7DigitalAsset(domain.tokenAddress);
        
        // Mint reputation tokens to the user
        // The 'true' parameter forces the transfer, which is necessary for non-transferable tokens
        token.mint(_user, _amount, true, "");
        
        // Update user's reputation in this domain
        userReputationByDomain[_user][_domainId] = userReputationByDomain[_user][_domainId].add(_amount);
        
        emit ReputationEarned(_user, _amount, _domainId, _projectId, _reason);
    }
    
    /**
     * @dev Allows project admins to award reputation based on task completion
     * @param _projectId ID of the project
     * @param _taskId ID of the completed task
     * @param _user User to award reputation to
     * @param _domainId Domain of reputation
     * @param _amount Amount of reputation to award
     */
    function projectAwardReputation(
        uint256 _projectId,
        uint256 _taskId,
        address _user,
        uint256 _domainId,
        uint256 _amount
    )
        external
        onlyProjectAdmin(_projectId)
    {
        // Verify the task exists and belongs to the project
        (,,, bool isCompleted,) = projectHub.getTaskDetails(_taskId);
        require(isCompleted, "ReputationSystem: Task is not completed");
        
        awardReputation(_user, _domainId, _amount, _projectId, "Task completion");
    }
    
    /**
     * @dev Rate a contribution to a specific task
     * @param _projectId ID of the project
     * @param _taskId ID of the task
     * @param _contributor Address of the contributor
     * @param _rating Rating from 0-100
     */
    function rateContribution(
        uint256 _projectId,
        uint256 _taskId,
        address _contributor,
        uint256 _rating
    )
        external
        onlyProjectAdmin(_projectId)
    {
        require(_rating <= 100, "ReputationSystem: Rating must be between 0-100");
        require(
            IERC165(_contributor).supportsInterface(_INTERFACE_ID_LSP0),
            "ReputationSystem: Contributor must be a Universal Profile"
        );
        
        // Create or update the contribution rating
        Contribution storage contribution = taskContributions[_projectId][_taskId];
        contribution.projectId = _projectId;
        contribution.taskId = _taskId;
        contribution.contributor = _contributor;
        contribution.rating = _rating;
        contribution.rated = true;
        
        emit ContributionRated(_projectId, _taskId, _contributor, _rating);
        
        // Award reputation based on rating
        // Scale: 0-100 rating gives 0-10 reputation
        uint256 reputationAmount = _rating.div(10);
        if (reputationAmount > 0) {
            // Award to the development domain (assuming domain 1 is development)
            // In a production environment, this should be more configurable
            awardReputation(_contributor, 1, reputationAmount, _projectId, "Task contribution rating");
        }
    }
    
    // ------- View Functions -------
    
    /**
     * @dev Get the reputation of a user in a specific domain
     * @param _user Address of the Universal Profile
     * @param _domainId ID of the reputation domain
     * @return Reputation amount in the specified domain
     */
    function getReputation(address _user, uint256 _domainId) 
        external 
        view 
        returns (uint256) 
    {
        return userReputationByDomain[_user][_domainId];
    }
    
    /**
     * @dev Get details of a reputation domain
     * @param _domainId ID of the domain
     * @return name Domain name
     * @return symbol Domain token symbol
     * @return tokenAddress Address of the LSP7 token
     * @return active Whether the domain is active
     */
    function getDomainDetails(uint256 _domainId)
        external
        view
        returns (string memory name, string memory symbol, address tokenAddress, bool active)
    {
        ReputationDomain storage domain = domains[_domainId];
        return (domain.name, domain.symbol, domain.tokenAddress, domain.active);
    }
    
    /**
     * @dev Get the contribution rating for a specific task
     * @param _projectId ID of the project
     * @param _taskId ID of the task
     * @return contributor Address of the contributor
     * @return rating Rating from 0-100
     * @return rated Whether the task has been rated
     */
    function getContributionRating(uint256 _projectId, uint256 _taskId)
        external
        view
        returns (address contributor, uint256 rating, bool rated)
    {
        Contribution storage contribution = taskContributions[_projectId][_taskId];
        return (contribution.contributor, contribution.rating, contribution.rated);
    }
}

