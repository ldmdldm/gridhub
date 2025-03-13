// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@lukso/lsp-smart-contracts/contracts/LSP0ERC725Account/ILSP0ERC725Account.sol";
import "@lukso/lsp-smart-contracts/contracts/LSP1UniversalReceiver/ILSP1UniversalReceiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ProjectHub.sol";

/**
 * @title TaskManager
 * @dev Advanced task management contract for GridHub platform
 *
 * This contract extends the ProjectHub's basic task management by adding:
 * 1. Task dependencies (tasks that must be completed before others)
 * 2. Deadline management with time-based incentives
 * 3. Subtasks for breaking down complex work items
 * 4. Peer review and approval workflows
 * 5. Automatic reward distribution
 *
 * LUKSO Integration:
 * - Uses Universal Profiles for all participants
 * - Sends notifications via LSP1 Universal Receiver
 * - Integrates with other GridHub contracts
 */
contract TaskManager is Ownable, ReentrancyGuard {
    
    // ------- Events -------
    event TaskCreated(uint256 indexed projectId, uint256 indexed taskId, string title, uint256 reward);
    event SubtaskCreated(uint256 indexed taskId, uint256 indexed subtaskId, string description);
    event TaskAssigned(uint256 indexed taskId, address indexed assignee);
    event TaskStarted(uint256 indexed taskId, address indexed assignee);
    event TaskDeadlineSet(uint256 indexed taskId, uint256 deadline);
    event TaskCompleted(uint256 indexed taskId, address indexed completer, uint256 timestamp);
    event TaskReviewed(uint256 indexed taskId, address indexed reviewer, bool approved, string feedback);
    event TaskRewarded(uint256 indexed taskId, address indexed recipient, uint256 amount);
    event PriorityChanged(uint256 indexed taskId, uint8 newPriority);
    
    // ------- Data Structures -------
    enum TaskStatus { CREATED, ASSIGNED, IN_PROGRESS, COMPLETED, REVIEWED, PAID }
    enum Priority { LOW, MEDIUM, HIGH, URGENT }
    
    struct Task {
        uint256 id;
        uint256 projectId;
        string title;
        string description;
        address assignee;
        uint256 reward;
        uint256 deadline;
        TaskStatus status;
        Priority priority;
        uint256 createdAt;
        uint256 completedAt;
        uint256[] dependencies; // IDs of tasks that must be completed first
        uint256[] subtaskIds;
        address[] reviewers;
        uint256 reviewsRequired;
        uint256 reviewsApproved;
        bool isPaid;
    }
    
    struct Subtask {
        uint256 id;
        uint256 parentTaskId;
        string description;
        bool isCompleted;
        address completedBy;
        uint256 completedAt;
    }
    
    struct Review {
        address reviewer;
        bool approved;
        string feedback;
        uint256 timestamp;
    }
    
    // ------- State Variables -------
    ProjectHub public projectHub;
    uint256 private nextTaskId = 1;
    uint256 private nextSubtaskId = 1;
    
    mapping(uint256 => Task) public tasks;
    mapping(uint256 => Subtask) public subtasks;
    mapping(uint256 => mapping(address => Review)) public taskReviews; // taskId => reviewer => Review
    mapping(uint256 => address[]) public taskReviewers; // taskId => list of reviewers
    
    // Optional token for reward payments
    IERC20 public rewardToken;
    bool public useExternalToken;
    
    // LSP0 interface ID for checking Universal Profiles
    bytes4 private constant _INTERFACE_ID_LSP0 = 0x6bb56a14;
    
    // ------- Constructor -------
    
    /**
     * @param _projectHubAddress Address of the ProjectHub contract
     */
    constructor(address _projectHubAddress) {
        projectHub = ProjectHub(_projectHubAddress);
    }
    
    // ------- Modifiers -------
    
    /**
     * @dev Checks if the sender is a valid Universal Profile
     */
    modifier onlyUniversalProfile() {
        require(
            IERC165(msg.sender).supportsInterface(_INTERFACE_ID_LSP0),
            "TaskManager: Caller must be a Universal Profile"
        );
        _;
    }
    
    /**
     * @dev Checks if the sender has project admin privileges
     */
    modifier onlyProjectAdmin(uint256 _projectId) {
        require(
            projectHub.getMemberRole(_projectId, msg.sender) >= uint8(ProjectHub.MemberRole.ADMIN),
            "TaskManager: Caller must be a project admin"
        );
        _;
    }
    
    /**
     * @dev Checks if the sender is the assignee of the task
     */
    modifier onlyAssignee(uint256 _taskId) {
        require(
            tasks[_taskId].assignee == msg.sender,
            "TaskManager: Caller must be the task assignee"
        );
        _;
    }
    
    /**
     * @dev Checks if a task exists
     */
    modifier taskExists(uint256 _taskId) {
        require(tasks[_taskId].createdAt > 0, "TaskManager: Task does not exist");
        _;
    }
    
    /**
     * @dev Checks if the task dependencies are completed
     */
    modifier dependenciesCompleted(uint256 _taskId) {
        Task storage task = tasks[_taskId];
        for (uint256 i = 0; i < task.dependencies.length; i++) {
            require(
                tasks[task.dependencies[i]].status == TaskStatus.COMPLETED || 
                tasks[task.dependencies[i]].status == TaskStatus.REVIEWED || 
                tasks[task.dependencies[i]].status == TaskStatus.PAID,
                "TaskManager: Dependencies must be completed first"
            );
        }
        _;
    }
    
    // ------- Task Management Functions -------
    
    /**
     * @dev Creates a new task with optional dependencies
     * @param _projectId Project ID
     * @param _title Task title
     * @param _description Detailed task description
     * @param _reward Amount of reward for completing the task
     * @param _dependencies IDs of tasks that must be completed before this one
     * @param _reviewsRequired Number of approvals required to finalize the task
     * @param _priority Priority level of the task
     * @return taskId ID of the newly created task
     */
    function createTask(
        uint256 _projectId,
        string memory _title,
        string memory _description,
        uint256 _reward,
        uint256[] memory _dependencies,
        uint256 _reviewsRequired,
        Priority _priority
    ) 
        external 
        onlyProjectAdmin(_projectId)
        returns (uint256) 
    {
        uint256 taskId = nextTaskId++;
        
        Task storage newTask = tasks[taskId];
        newTask.id = taskId;
        newTask.projectId = _projectId;
        newTask.title = _title;
        newTask.description = _description;
        newTask.reward = _reward;
        newTask.status = TaskStatus.CREATED;
        newTask.priority = _priority;
        newTask.createdAt = block.timestamp;
        newTask.dependencies = _dependencies;
        newTask.reviewsRequired = _reviewsRequired > 0 ? _reviewsRequired : 1;
        
        emit TaskCreated(_projectId, taskId, _title, _reward);
        
        return taskId;
    }
    
    /**
     * @dev Creates a subtask for a main task
     * @param _taskId Parent task ID
     * @param _description Subtask description
     * @return subtaskId ID of the newly created subtask
     */
    function createSubtask(uint256 _taskId, string memory _description) 
        external 
        taskExists(_taskId)
        onlyProjectAdmin(tasks[_taskId].projectId)
        returns (uint256) 
    {
        uint256 subtaskId = nextSubtaskId++;
        
        Subtask storage newSubtask = subtasks[subtaskId];
        newSubtask.id = subtaskId;
        newSubtask.parentTaskId = _taskId;
        newSubtask.description = _description;
        
        tasks[_taskId].subtaskIds.push(subtaskId);
        
        emit SubtaskCreated(_taskId, subtaskId, _description);
        
        return subtaskId;
    }
    
    /**
     * @dev Assigns a task to a project member
     * @param _taskId Task ID
     * @param _assignee Address of the Universal Profile to assign
     */
    function assignTask(uint256 _taskId, address _assignee) 
        external 
        taskExists(_taskId)
        onlyProjectAdmin(tasks[_taskId].projectId)
    {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.CREATED, "TaskManager: Task already assigned");
        require(
            IERC165(_assignee).supportsInterface(_INTERFACE_ID_LSP0),
            "TaskManager: Assignee must be a Universal Profile"
        );
        
        // Check if the assignee is a project member
        require(
            projectHub.getMemberRole(task.projectId, _assignee) >= uint8(ProjectHub.MemberRole.CONTRIBUTOR),
            "TaskManager: Assignee must be a project contributor or higher"
        );
        
        task.assignee = _assignee;
        task.status = TaskStatus.ASSIGNED;
        
        // Notify the assignee using LSP1
        try ILSP1UniversalReceiver(_assignee).universalReceiver(
            bytes32("TASK_ASSIGNED"),
            abi.encode(task.projectId, _taskId, msg.sender)
        ) {} catch {}
        
        emit TaskAssigned(_taskId, _assignee);
    }
    
    /**
     * @dev Marks a task as started by the assignee
     * @param _taskId Task ID
     */
    function startTask(uint256 _taskId) 
        external 
        taskExists(_taskId)
        onlyAssignee(_taskId)
        dependenciesCompleted(_taskId)
    {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.ASSIGNED, "TaskManager: Task not in assigned state");
        
        task.status = TaskStatus.IN_PROGRESS;
        
        emit TaskStarted(_taskId, msg.sender);
    }
    
    /**
     * @dev Sets a deadline for a task
     * @param _taskId Task ID
     * @param _deadline Timestamp of the deadline
     */
    function setTaskDeadline(uint256 _taskId, uint256 _deadline) 
        external 
        taskExists(_taskId)
        onlyProjectAdmin(tasks[_taskId].projectId)
    {
        require(_deadline > block.timestamp, "TaskManager: Deadline must be in the future");
        tasks[_taskId].deadline = _deadline;
        
        emit TaskDeadlineSet(_taskId, _deadline);
    }
    
    /**
     * @dev Marks a task as completed by the assignee
     * @param _taskId Task ID
     */
    function completeTask(uint256 _taskId) 
        external 
        taskExists(_taskId)
        onlyAssignee(_taskId)
        dependenciesCompleted(_taskId)
    {
        Task storage task = tasks[_taskId];
        require(
            task.status == TaskStatus.IN_PROGRESS,
            "TaskManager: Task must be in progress"
        );
        
        // Check if all subtasks are completed if there are any
        if (task.subtaskIds.length > 0) {
            for (uint256 i = 0; i < task.subtaskIds.length; i++) {
                require(
                    subtasks[task.subtaskIds[i]].isCompleted,
                    "TaskManager: All subtasks must be completed first"
                );
            }
        }
        
        task.status = TaskStatus.COMPLETED;
        task.completedAt = block.timestamp;
        
        emit TaskCompleted(_taskId, msg.sender, block.timestamp);
        
        // If no reviews are required, automatically mark as reviewed
        if (task.reviewsRequired == 0) {
            task.status = TaskStatus.REVIEWED;
            
            // If there's a reward, distribute it
            if (task.reward > 0) {
                _distributeReward(_taskId);
            }
        }
    }
    
    /**
     * @dev Completes a subtask
     * @param _subtaskId Subtask ID
     */
    function completeSubtask(uint256 _subtaskId) 
        external 
        onlyUniversalProfile
    {
        Subtask storage subtask = subtasks[_subtaskId];
        require(subtask.id == _subtaskId, "TaskManager: Subtask does not exist");
        require(!subtask.isCompleted, "TaskManager: Subtask already completed");
        
        uint256 taskId = subtask.parentTaskId;
        Task storage task = tasks[taskId];
        
        // Check if the caller is the task assignee or an admin
        require(
            task.assignee == msg.sender || 
            projectHub.getMemberRole(task.projectId, msg.sender) >= uint8(ProjectHub.MemberRole.ADMIN),
            "TaskManager: Not authorized to complete subtask"
        );
        
        subtask.isCompleted = true;
        subtask.completedBy = msg.sender;
        subtask.completedAt = block.timestamp;
    }
    
    /**
     * @dev Reviews a completed task
     * @param _taskId Task ID
     * @param _approved Whether the reviewer approves the task
     * @param _feedback Feedback from the reviewer
     */
    function reviewTask(uint256 _taskId, bool _approved, string memory _feedback) 
        external 
        taskExists(_taskId)
        onlyUniversalProfile
    {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.COMPLETED, "TaskManager: Task must be completed before review");
        
        // Check if the caller is an admin or authorized reviewer
        require(
            projectHub.getMemberRole(task.projectId, msg.sender) >= uint8(ProjectHub.MemberRole.ADMIN),
            "TaskManager: Caller must be a project admin"
        );
        
        // Check if the reviewer has already reviewed this task
        require(
            taskReviews[_taskId][msg.sender].timestamp == 0,
            "TaskManager: You have already reviewed this task"
        );
        
        // Record the review
        taskReviews[_taskId][msg.sender] = Review({
            reviewer: msg.sender,
            approved: _approved,
            feedback: _feedback,
            timestamp: block.timestamp
        });
        

