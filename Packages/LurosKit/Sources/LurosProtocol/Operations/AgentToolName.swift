/// Every tool an agent session offers, by the name the model calls it and
/// the session's events record it. LurosAgent says what each one does
/// (`ToolCatalog`); the session host and the app read the names from here,
/// so a rename reaches all three at once.
///
/// A tool that acts on what Luros keeps — its projects and templates, the
/// packages it installs, the device, toolchains and SDKs, conversations,
/// memory, skills, its settings — or reaches past the device, as the web
/// fetch does, is `luros_<scope>_<verb>`; a generic verb on the session's
/// own project is `<domain>_<verb>`: `file_*`, `shell_run` and the
/// repository's `git_*`. MCP tools keep kwwk's `mcp__<server>__<tool>`.
public enum AgentToolName: String, Sendable, Hashable, Codable, CaseIterable {
    case fileWrite = "file_write"
    case fileEdit = "file_edit"
    case fileCreate = "file_create"
    case fileRead = "file_read"
    case fileList = "file_list"
    case fileGrep = "file_grep"
    case fileFind = "file_find"
    case fileShow = "file_show"
    case shellRun = "shell_run"
    case sdkAnalyzeFramework = "luros_sdk_analyze_framework"
    case sdkReadHeader = "luros_sdk_read_header"
    case projectBuild = "luros_project_build"
    case packageInstall = "luros_package_install"
    case packageRemove = "luros_package_remove"
    case packageList = "luros_package_list"
    case packagePublish = "luros_package_publish"
    case deviceRespring = "luros_device_respring"
    case packageConfirmLoaded = "luros_package_confirm_loaded"
    case logRead = "luros_log_read"
    case crashList = "luros_crash_list"
    case crashRead = "luros_crash_read"
    case crashSymbolicate = "luros_crash_symbolicate"
    case screenCapture = "luros_screen_capture"
    case screenReadTree = "luros_screen_read_tree"
    case screenInteract = "luros_screen_interact"
    case memoryList = "luros_memory_list"
    case memorySave = "luros_memory_save"
    case memoryDelete = "luros_memory_delete"
    /// The conversation's todo list, as the composer shows it.
    case todoList = "luros_todo_list"
    case todoWrite = "luros_todo_write"
    case skillList = "luros_skill_list"
    case skillRead = "luros_skill_read"
    case skillSave = "luros_skill_save"
    case skillRemove = "luros_skill_remove"
    case notificationSend = "luros_notification_send"
    /// A question for the reader, which the call waits on (`AgentQuestion`).
    case questionAsk = "luros_question_ask"
    /// The conversation's own run mode, changed by the agent (`AgentRunModeRequest`).
    case runMode = "luros_run_mode"
    case webSearch = "web_search"
    case webFetch = "luros_web_fetch"
    case feedbackSend = "luros_feedback_send"
    case feedbackRead = "luros_feedback_read"
    case feedbackEdit = "luros_feedback_edit"
    case projectCheckDistribution = "luros_project_check_distribution"
    case templateList = "luros_template_list"
    case projectList = "luros_project_list"
    case projectCreate = "luros_project_create"
    case projectRename = "luros_project_rename"
    case projectDelete = "luros_project_delete"
    case gitStatus = "git_status"
    case gitDiff = "git_diff"
    case gitStage = "git_stage"
    case gitUnstage = "git_unstage"
    case gitCommit = "git_commit"
    case gitInit = "git_init"
    case gitBranches = "git_branches"
    case gitBranchCreate = "git_branch_create"
    case gitBranchCheckout = "git_branch_checkout"
    case gitBranchDelete = "git_branch_delete"
    case gitBranchRename = "git_branch_rename"
    case gitMerge = "git_merge"
    case gitMergeAbort = "git_merge_abort"
    case gitLog = "git_log"
    case gitCommitDetail = "git_commit_detail"
    case gitFetch = "git_fetch"
    case gitPull = "git_pull"
    case gitPush = "git_push"
    case gitClone = "git_clone"
    case gitSquash = "git_squash"
    case gitTag = "git_tag"
    case gitStash = "git_stash"
    case gitRestore = "git_restore"
    case gitClean = "git_clean"
    case gitRemoteList = "git_remote_list"
    case gitRemoteSet = "git_remote_set"
    case gitRemoteRemove = "git_remote_remove"
    case gitResetToRemote = "git_reset_to_remote"
    case gitReadSettings = "luros_git_read_settings"
    case gitSetAuthor = "luros_git_set_author"
    case gitSaveCredential = "luros_git_save_credential"
    case gitRemoveCredential = "luros_git_remove_credential"
    case gitCreateRepository = "luros_git_create_repository"
    case gitCreateIssue = "luros_git_create_issue"
    case conversationCreate = "luros_conversation_create"
    case conversationSend = "luros_conversation_send"
    case conversationList = "luros_conversation_list"
    case conversationRead = "luros_conversation_read"
    case conversationStop = "luros_conversation_stop"
    /// The host-kept delegation plan of a conversation an agent opened
    /// (`AgentDelegation`): read, and the moves its owner may ask for.
    case conversationPlan = "luros_conversation_plan"
    case toolchainList = "luros_toolchain_list"
    case sdkList = "luros_sdk_list"
    case toolchainSetup = "luros_toolchain_setup"
    case sdkImport = "luros_sdk_import"
    case toolchainSelfTest = "luros_toolchain_self_test"
    case projectSetEnvironment = "luros_project_set_environment"
}

public extension AgentToolName {
    /// The names earlier builds gave a tool (0.1.8 and before, and
    /// `notify_user` after it), for the events and transcripts recorded
    /// then. None of them is a current name.
    static let legacyNames: [String: AgentToolName] = [
        "write_file": .fileWrite,
        "patch_file": .fileEdit,
        "create_file": .fileCreate,
        "read_file": .fileRead,
        "list": .fileList,
        "grep": .fileGrep,
        "find": .fileFind,
        "run_code": .shellRun,
        "analyze_framework": .sdkAnalyzeFramework,
        "framework_header": .sdkReadHeader,
        "build": .projectBuild,
        "install": .packageInstall,
        "remove_package": .packageRemove,
        "respring": .deviceRespring,
        "confirm_loaded": .packageConfirmLoaded,
        "read_logs": .logRead,
        "list_crashes": .crashList,
        "read_crash": .crashRead,
        "symbolicate_crash": .crashSymbolicate,
        "capture_screen": .screenCapture,
        "read_ui_tree": .screenReadTree,
        "ui_action": .screenInteract,
        "memory_list": .memoryList,
        "memory_save": .memorySave,
        "memory_delete": .memoryDelete,
        "read_skill": .skillRead,
        "notify_user": .notificationSend,
        "check_distribution": .projectCheckDistribution,
        "project_template_list": .templateList,
        "project_create": .projectCreate,
        "git_settings": .gitReadSettings,
        "git_set_author": .gitSetAuthor,
        "git_save_credential": .gitSaveCredential,
        "git_remove_credential": .gitRemoveCredential,
        "conversation_create": .conversationCreate,
        "conversation_send": .conversationSend,
        "conversation_list": .conversationList,
        "conversation_read": .conversationRead,
        "conversation_stop": .conversationStop,
        "conversation_plan": .conversationPlan,
        "toolchain_list": .toolchainList,
        "sdk_list": .sdkList,
        "toolchain_setup": .toolchainSetup,
        "sdk_import": .sdkImport,
        "toolchain_self_test": .toolchainSelfTest,
        "project_environment_set": .projectSetEnvironment,
    ]

    /// The tool a recorded name means: a current name or one an earlier
    /// release used; nil for any other, such as an MCP server's.
    static func canonical(_ name: String) -> AgentToolName? {
        AgentToolName(rawValue: name) ?? legacyNames[name]
    }
}
