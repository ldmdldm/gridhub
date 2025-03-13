// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// Import LUKSO's LSP interfaces
import "@lukso/lsp-smart-contracts/contracts/LSP0ERC725Account/ILSP0ERC725Account.sol";
import "@lukso/lsp-smart-contracts/contracts/LSP6KeyManager/ILSP6KeyManager.sol";
import "@lukso/lsp-smart-contracts/contracts/LSP1UniversalReceiver/ILSP1UniversalReceiver.sol";
import "@lukso/lsp-smart-contracts/contracts/LSP2ERC725YJSONSchema/LSP2Constants.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title ProjectHub
 * @dev Core contract for managing collaborative projects in the GridHub platform
 * 
 * This contract enables Universal Profile owners to:
 * 1. Create and manage collaborative projects
 * 2. Assign and track tasks within projects
 * 3. Record contributions and manage project memberships
 * 
 * LUKSO Integration:
 * - Uses Universal Profiles as user identities
 * - Leverages LSP0 (ERC725Account) for profile verification
 * - Utilizes LSP1 (UniversalReceiver) for notifications
 * - Uses ERC725Y data keys from LSP2 for metadata storage
 */
contract ProjectHub is Ownable, ReentrancyGuard {
    // ------- Events -------
    event ProjectCreated(uint256 indexed projectId, address indexed creator, string name);
    event MemberAdded(uint256 indexed projectId, address indexed member, uint8 role);
    event TaskCreated(uint256 indexed projectId, uint256 indexed taskId, string description);
    event TaskAssigned(uint256 indexed taskId, address indexed assignee);
    event TaskCompleted(uint256 indexed taskId, address indexed completedBy, uint256 completedAt);
    event ContributionRecorded(uint256 indexed projectId, address indexed contributor, uint256 value);
    
    // ------- Data Structures -------
    enum MemberRole { NONE, VIEWER, CONTRIBUTOR, ADMIN, OWNER }
    
    struct Project {
        uint256 id;
        string name;
        string description;
        address creator;
        bool isActive;
        uint256 createdAt;
        uint256 memberCount;
        uint256[] taskIds;
    }
    
    struct Task {
        uint256 id;
        uint256 projectId;
        string description;
        address assignee;
        bool isCompleted;
        uint256 createdAt;
        uint256 completedAt;
        string deliverables; // IPFS hash or other reference to deliverables
    }
    
    struct Contribution {
        uint256 projectId;
        address contributor;
        uint256 timestamp;
        uint256 value;
        string description;
    }
    
    // ------- State Variables -------
    uint256 private nextProjectId = 1;
    uint256 private nextTaskId = 1;
    uint256 private nextContributionId = 1;
    
    mapping(uint256 => Project) public projects;
    mapping(uint256 => Task) public tasks;
    mapping(uint256 => Contribution) public contributions;
    
    // Project membership mapping: projectId => userAddress => role
    mapping(uint256 => mapping(address => MemberRole)) public projectMembers;
    
    // Project contributions mapping: projectId => userAddress => totalContribution
    mapping(uint256 => mapping(address => uint256)) public projectContributions;
    
    // LSP0 interface ID for checking Universal Profiles
    bytes4 private constant _INTERFACE_ID_LSP0 = 0x6bb56a14;
    
    // ------- Modifiers -------
    
    /**
     * @dev Checks if the sender is a valid Universal Profile
     * Uses LUKSO's ILSP0ERC725Account interface detection
     */
    modifier onlyUniversalProfile() {
        require(
            IERC165(msg.sender).supportsInterface(_INTERFACE_ID_LSP0),
            "ProjectHub: Caller must be a Universal Profile"
        );
        _;
    }
    
    /**
     * @dev Checks if the sender has the required role for a project
     * Used for permission control within projects
     */
    modifier hasRole(uint256 _projectId, MemberRole _requiredRole) {
        require(
            projectMembers[_projectId][msg.sender] >= _requiredRole,
            "ProjectHub: Insufficient permissions"
        );
        _;
    }
    
    /**
     * @dev Checks if a project exists
     */
    modifier projectExists(uint256 _projectId) {
        require(projects[_projectId].creator != address(0), "ProjectHub: Project does not exist");
        _;
    }
    
    // ------- Core Functions -------
    
    /**
     * @dev Creates a new project in the GridHub ecosystem
     * @param _name Name of the project
     * @param _description Brief description of the project
     * @return projectId The ID of the newly created project
     * 
     * Note: Only Universal Profiles can create projects
     */
    function createProject(string memory _name, string memory _description) 
        external 
        onlyUniversalProfile
        returns (uint256) 
    {
        uint256 projectId = nextProjectId++;
        
        Project storage newProject = projects[projectId];
        newProject.id = projectId;
        newProject.name = _name;
        newProject.description = _description;
        newProject.creator = msg.sender;
        newProject.isActive = true;
        newProject.createdAt = block.timestamp;
        newProject.memberCount = 1; // Creator is the first member
        
        // Set creator as the project owner
        projectMembers[projectId][msg.sender] = MemberRole.OWNER;
        
        emit ProjectCreated(projectId, msg.sender, _name);
        
        return projectId;
    }
    
    /**
     * @dev Adds a member to a project
     * @param _projectId ID of the project
     * @param _member Address of the Universal Profile to add
     * @param _role Role to assign to the member
     * 
     * LUKSO Integration: Verifies that the member address is a Universal Profile
     * before adding them to the project
     */
    function addMember(uint256 _projectId, address _member, MemberRole _role) 
        external 
        projectExists(_projectId)
        hasRole(_projectId, MemberRole.ADMIN)
    {
        require(_role != MemberRole.NONE, "ProjectHub: Invalid role");
        require(
            IERC165(_member).supportsInterface(_INTERFACE_ID_LSP0),
            "ProjectHub: Member must be a Universal Profile"
        );
        
        // If this is a new member, increment count
        if (projectMembers[_projectId][_member] == MemberRole.NONE) {
            projects[_projectId].memberCount++;
        }
        
        projectMembers[_projectId][_member] = _role;
        
        // Optional: Notify the Universal Profile about being added to a project
        // This leverages LSP1 UniversalReceiver functionality
        try ILSP1UniversalReceiver(_member).universalReceiver(
            bytes32("PROJECT_INVITE"),
            abi.encode(_projectId, msg.sender, uint8(_role))
        ) {} catch {}
        
        emit MemberAdded(_projectId, _member, uint8(_role));
    }
    
    /**
     * @dev Creates a new task in a project
     * @param _projectId ID of the project
     * @param _description Description of the task
     * @return taskId The ID of the newly created task
     */
    function createTask(uint256 _projectId, string memory _description) 
        external 
        projectExists(_projectId)
        hasRole(_projectId, MemberRole.CONTRIBUTOR)
        returns (uint256) 
    {
        uint256 taskId = nextTaskId++;
        
        Task storage newTask = tasks[taskId];
        newTask.id = taskId;
        newTask.projectId = _projectId;
        newTask.description = _description;
        newTask.createdAt = block.timestamp;
        
        projects[_projectId].taskIds.push(taskId);
        
        emit TaskCreated(_projectId, taskId, _description);
        
        return taskId;
    }
    
    /**
     * @dev Assigns a task to a project member
     * @param _taskId ID of the task
     * @param _assignee Address of the Universal Profile to assign the task to
     */
    function assignTask(uint256 _taskId, address _assignee) 
        external 
        hasRole(tasks[_taskId].projectId, MemberRole.ADMIN)
    {
        Task storage task = tasks[_taskId];
        require(!task.isCompleted, "ProjectHub: Task already completed");
        require(
            projectMembers[task.projectId][_assignee] >= MemberRole.CONTRIBUTOR,
            "ProjectHub: Assignee must be a project contributor or higher"
        );
        
        task.assignee = _assignee;
        
        emit TaskAssigned(_taskId, _assignee);
    }
    
    /**
     * @dev Marks a task as completed
     * @param _taskId ID of the task
     * @param _deliverables IPFS hash or other reference to deliverables
     */
    function completeTask(uint256 _taskId, string memory _deliverables) 
        external 
        nonReentrant
    {
        Task storage task = tasks[_taskId];
        require(!task.isCompleted, "ProjectHub: Task already completed");
        require(
            task.assignee == msg.sender || 
            projectMembers[task.projectId][msg.sender] >= MemberRole.ADMIN,
            "ProjectHub: Only assignee or admin can complete task"
        );
        
        task.isCompleted = true;
        task.completedAt = block.timestamp;
        task.deliverables = _deliverables;
        
        // Record a contribution
        recordContribution(
            task.projectId,
            msg.sender,
            1, // Base value for completing a task
            string(abi.encodePacked("Completed task: ", task.description))
        );
        
        emit TaskCompleted(_taskId, msg.sender, block.timestamp);
    }
    
    /**
     * @dev Records a contribution to a project
     * @param _projectId ID of the project
     * @param _value Numeric value representing the contribution's worth
     * @param _description Description of the contribution
     * 
     * This function allows tracking of contributions beyond just task completion
     */
    function recordContribution(
        uint256 _projectId,
        address _contributor,
        uint256 _value,
        string memory _description
    ) 
        public 
        projectExists(_projectId)
        hasRole(_projectId, MemberRole.ADMIN)
    {
        require(_value > 0, "ProjectHub: Contribution value must be positive");
        
        uint256 contributionId = nextContributionId++;
        
        Contribution storage newContribution = contributions[contributionId];
        newContribution.projectId = _projectId;
        newContribution.contributor = _contributor;
        newContribution.timestamp = block.timestamp;
        newContribution.value = _value;
        newContribution.description = _description;
        
        // Update total contribution for this user
        projectContributions[_projectId][_contributor] += _value;
        
        emit ContributionRecorded(_projectId, _contributor, _value);
    }
    
    /**
     * @dev Retrieves project details
     * @param _projectId ID of the project
     * @return Project details including tasks and member count
     */
    function getProjectDetails(uint256 _projectId) 
        external 
        view 
        projectExists(_projectId)
        returns (
            string memory name,
            string memory description,
            address creator,
            bool isActive,
            uint256 createdAt,
            uint256 memberCount,
            uint256[] memory taskIds
        ) 
    {
        Project storage project = projects[_projectId];
        return (
            project.name,
            project.description,
            project.creator,
            project.isActive,
            project.createdAt,
            project.memberCount,
            project.taskIds
        );
    }
    
    /**
     * @dev Gets a user's contribution to a specific project
     * @param _projectId ID of the project
     * @param _contributor Address of the contributor
     * @return Total contribution value
     */
    function getContribution(uint256 _projectId, address _contributor) 
        external 
        view 
        returns (uint256) 
    {
        return projectContributions[_projectId][_contributor];
    }
    
    /**
     * @dev Checks if an address is a member of a project
     * @param _projectId ID of the project
     * @param _address Address to check
     * @return Role of the address in the project
     */
    function getMemberRole(uint256 _projectId, address _address) 
        external 
        view 
        returns (MemberRole) 
    {
        return projectMembers[_projectId][_address];
    }
    
    /**
     * @dev Store additional metadata about a project using LUKSO's ERC725Y standard
     * @param _projectId ID of the project
     * @param _key The data key to set (should follow LSP2 conventions)
     * @param _value The data value to set
     * 
     * LUKSO Integration: Uses ERC725Y data schema from LSP2 for standardized metadata
     */
    function setProjectMetadata(uint256 _projectId, bytes32 _key, bytes memory _value) 
        external 
        projectExists(_projectId)
        hasRole(_projectId, MemberRole.ADMIN)
    {
        // Optional: Store metadata in project creator's Universal Profile
        // This leverages the data storage capabilities of Universal Profiles
        try ILSP0ERC725Account(projects[_projectId].creator).setData(
            bytes32(bytes.concat(
                bytes("ProjectHub:metadata:"),
                bytes32(abi.encode(_projectId)),
                _key
            )),
            _value
        ) {} catch {
            // Fallback if setting data on the Universal Profile fails
            // Could implement on-chain storage as backup
        }
    }
}

