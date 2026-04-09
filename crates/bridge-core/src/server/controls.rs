use std::path::Path;
use std::process::Command;

use serde::Serialize;
use serde_json::{Value, json};
use shared_contracts::{BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, GitStatusDto};

use crate::thread_api::{GitStatusResponse, MutationResultResponse, RepositoryContextDto};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalStatus {
    Pending,
    Approved,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PendingApprovalAction {
    BranchSwitch {
        thread_id: String,
        branch: String,
    },
    Pull {
        thread_id: String,
        remote: Option<String>,
    },
    Push {
        thread_id: String,
        remote: Option<String>,
    },
}

impl PendingApprovalAction {
    pub fn thread_id(&self) -> &str {
        match self {
            Self::BranchSwitch { thread_id, .. }
            | Self::Pull { thread_id, .. }
            | Self::Push { thread_id, .. } => thread_id,
        }
    }

    pub fn operation_name(&self) -> &'static str {
        match self {
            Self::BranchSwitch { .. } => "git_branch_switch",
            Self::Pull { .. } => "git_pull",
            Self::Push { .. } => "git_push",
        }
    }

    pub fn target_name(&self) -> String {
        match self {
            Self::BranchSwitch { branch, .. } => branch.clone(),
            Self::Pull { remote, .. } => remote.clone().unwrap_or_else(|| "origin".to_string()),
            Self::Push { remote, .. } => remote.clone().unwrap_or_else(|| "origin".to_string()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ApprovalRecordDto {
    pub contract_version: String,
    pub approval_id: String,
    pub thread_id: String,
    pub action: String,
    pub target: String,
    pub reason: String,
    pub status: ApprovalStatus,
    pub requested_at: String,
    pub resolved_at: Option<String>,
    pub repository: RepositoryContextDto,
    pub git_status: crate::thread_api::GitStatusDto,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ApprovalGateResponse {
    pub contract_version: String,
    pub operation: String,
    pub outcome: String,
    pub message: String,
    pub approval: ApprovalRecordDto,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ApprovalResolutionResponse {
    pub contract_version: String,
    pub approval: ApprovalRecordDto,
    pub mutation_result: Option<MutationResultResponse>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedGitState {
    pub response: GitStatusResponse,
    pub snapshot_status: GitStatusDto,
    pub branch: String,
    pub remote_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecutedGitMutation {
    pub mutation: MutationResultResponse,
    pub command_event: BridgeEventEnvelope<Value>,
    pub snapshot_status: GitStatusDto,
}

struct ExecutedMutationContext {
    operation: &'static str,
    message: String,
    command: String,
    output: String,
}

pub fn read_git_state(workspace: &str, thread_id: &str) -> Result<ResolvedGitState, String> {
    let workspace = normalize_workspace(workspace)?;
    let top_level = run_git(workspace, ["rev-parse", "--show-toplevel"])?;
    let branch = run_git(workspace, ["rev-parse", "--abbrev-ref", "HEAD"])?;
    let remote_name = resolve_remote_name(workspace, &branch)?;
    let dirty = !run_git(workspace, ["status", "--porcelain"])?.is_empty();
    let (ahead_by, behind_by) = read_ahead_behind(workspace)?;
    let repository = repository_name(workspace, remote_name.as_deref())?;
    let repository_context = RepositoryContextDto {
        workspace: top_level.clone(),
        repository,
        branch: branch.clone(),
        remote: remote_name.clone().unwrap_or_else(|| "unknown".to_string()),
    };
    let mutation_status = crate::thread_api::GitStatusDto {
        dirty,
        ahead_by,
        behind_by,
    };

    Ok(ResolvedGitState {
        snapshot_status: GitStatusDto {
            workspace: top_level,
            repository: repository_context.repository.clone(),
            branch: branch.clone(),
            remote: remote_name.clone(),
            dirty,
            ahead_by,
            behind_by,
        },
        response: GitStatusResponse {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: thread_id.to_string(),
            repository: repository_context,
            status: mutation_status,
        },
        branch,
        remote_name,
    })
}

pub fn read_git_state_for_status(
    workspace: &str,
    thread_id: &str,
) -> Result<ResolvedGitState, String> {
    match read_git_state(workspace, thread_id) {
        Ok(state) => Ok(state),
        Err(error) if is_not_git_repository_error(&error) => {
            let workspace = normalize_workspace(workspace)?;
            Ok(non_repository_git_state(workspace, thread_id))
        }
        Err(error) => Err(error),
    }
}

pub fn execute_branch_switch(
    workspace: &str,
    thread_id: &str,
    branch: &str,
    thread_status: shared_contracts::ThreadStatus,
    occurred_at: &str,
) -> Result<ExecutedGitMutation, String> {
    let workspace = normalize_workspace(workspace)?;
    let branch = branch.trim();
    if branch.is_empty() {
        return Err("Branch name cannot be empty.".to_string());
    }
    let _ = run_git(
        workspace,
        ["rev-parse", "--verify", &format!("refs/heads/{branch}")],
    )?;
    let output = run_git(workspace, ["switch", branch])?;
    build_executed_mutation(
        workspace,
        thread_id,
        thread_status,
        occurred_at,
        ExecutedMutationContext {
            operation: "git_branch_switch",
            message: format!("Switched branch to {branch}"),
            command: format!("git switch {branch}"),
            output,
        },
    )
}

pub fn execute_pull(
    workspace: &str,
    thread_id: &str,
    remote: Option<&str>,
    thread_status: shared_contracts::ThreadStatus,
    occurred_at: &str,
) -> Result<ExecutedGitMutation, String> {
    let workspace = normalize_workspace(workspace)?;
    let branch = run_git(workspace, ["rev-parse", "--abbrev-ref", "HEAD"])?;
    let remote = resolve_remote_override(workspace, &branch, remote)?;
    let output = run_git(workspace, ["pull", "--ff-only", &remote, &branch])?;
    build_executed_mutation(
        workspace,
        thread_id,
        thread_status,
        occurred_at,
        ExecutedMutationContext {
            operation: "git_pull",
            message: format!("Pulled latest changes from {remote} for {branch}"),
            command: format!("git pull --ff-only {remote} {branch}"),
            output,
        },
    )
}

pub fn execute_push(
    workspace: &str,
    thread_id: &str,
    remote: Option<&str>,
    thread_status: shared_contracts::ThreadStatus,
    occurred_at: &str,
) -> Result<ExecutedGitMutation, String> {
    let workspace = normalize_workspace(workspace)?;
    let branch = run_git(workspace, ["rev-parse", "--abbrev-ref", "HEAD"])?;
    let remote = resolve_remote_override(workspace, &branch, remote)?;
    let output = run_git(workspace, ["push", &remote, &branch])?;
    build_executed_mutation(
        workspace,
        thread_id,
        thread_status,
        occurred_at,
        ExecutedMutationContext {
            operation: "git_push",
            message: format!("Pushed local commits to {remote} for {branch}"),
            command: format!("git push {remote} {branch}"),
            output,
        },
    )
}

fn build_executed_mutation(
    workspace: &Path,
    thread_id: &str,
    thread_status: shared_contracts::ThreadStatus,
    occurred_at: &str,
    context: ExecutedMutationContext,
) -> Result<ExecutedGitMutation, String> {
    let state = read_git_state(workspace.to_string_lossy().as_ref(), thread_id)?;
    let command_event = BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: format!("{thread_id}-{}-{occurred_at}", context.operation),
        thread_id: thread_id.to_string(),
        kind: BridgeEventKind::CommandDelta,
        occurred_at: occurred_at.to_string(),
        payload: json!({
            "command": context.command,
            "output": if context.output.trim().is_empty() {
                context.message.clone()
            } else {
                context.output
            },
            "action": context.operation,
        }),
        annotations: None,
        bridge_seq: None,
    };

    Ok(ExecutedGitMutation {
        snapshot_status: state.snapshot_status,
        mutation: MutationResultResponse {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: thread_id.to_string(),
            operation: context.operation.to_string(),
            outcome: "success".to_string(),
            message: context.message,
            thread_status,
            repository: state.response.repository,
            status: state.response.status,
        },
        command_event,
    })
}

fn normalize_workspace(workspace: &str) -> Result<&Path, String> {
    let trimmed = workspace.trim();
    if trimmed.is_empty() {
        return Err("Git workspace is unavailable for this thread.".to_string());
    }
    let path = Path::new(trimmed);
    if !path.exists() {
        return Err(format!("Git workspace does not exist: {trimmed}"));
    }
    Ok(path)
}

fn resolve_remote_override(
    workspace: &Path,
    branch: &str,
    remote: Option<&str>,
) -> Result<String, String> {
    if let Some(remote) = remote.map(str::trim).filter(|value| !value.is_empty()) {
        return Ok(remote.to_string());
    }

    resolve_remote_name(workspace, branch)?
        .ok_or_else(|| "No git remote is configured for this branch.".to_string())
}

fn resolve_remote_name(workspace: &Path, branch: &str) -> Result<Option<String>, String> {
    match run_git(
        workspace,
        [
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ],
    ) {
        Ok(upstream) => {
            let remote = upstream
                .split('/')
                .next()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string);
            if remote.is_some() {
                return Ok(remote);
            }
        }
        Err(error) if error.contains("no upstream configured") => {}
        Err(error) if error.contains("does not point to a branch") => {}
        Err(error) => return Err(error),
    }

    let remotes = run_git(workspace, ["remote"])?;
    let remote = remotes
        .lines()
        .map(str::trim)
        .find(|value| !value.is_empty())
        .map(ToString::to_string);

    if remote.is_none() && !branch.trim().is_empty() {
        return Ok(None);
    }

    Ok(remote)
}

fn read_ahead_behind(workspace: &Path) -> Result<(u32, u32), String> {
    let upstream = match run_git(
        workspace,
        [
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ],
    ) {
        Ok(upstream) => upstream,
        Err(error) if error.contains("no upstream configured") => return Ok((0, 0)),
        Err(error) if error.contains("does not point to a branch") => return Ok((0, 0)),
        Err(error) => return Err(error),
    };

    let counts = run_git(
        workspace,
        [
            "rev-list",
            "--left-right",
            "--count",
            &format!("HEAD...{upstream}"),
        ],
    )?;
    let mut parts = counts.split_whitespace();
    let ahead_by = parts
        .next()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(0);
    let behind_by = parts
        .next()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(0);
    Ok((ahead_by, behind_by))
}

fn repository_name(workspace: &Path, remote_name: Option<&str>) -> Result<String, String> {
    if let Some(remote_name) = remote_name {
        let remote_url = run_git(workspace, ["remote", "get-url", remote_name])?;
        if let Some(name) = parse_repository_name_from_remote(&remote_url) {
            return Ok(name);
        }
    }

    workspace
        .file_name()
        .and_then(|value| value.to_str())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "Unable to resolve repository name for this thread.".to_string())
}

fn parse_repository_name_from_remote(remote_url: &str) -> Option<String> {
    let trimmed = remote_url.trim().trim_end_matches('/');
    let last_segment = trimmed
        .rsplit('/')
        .next()
        .or_else(|| trimmed.rsplit(':').next())?;
    let repository = last_segment.trim().trim_end_matches(".git").trim();
    (!repository.is_empty()).then(|| repository.to_string())
}

fn non_repository_git_state(workspace: &Path, thread_id: &str) -> ResolvedGitState {
    let repository_context = RepositoryContextDto {
        workspace: workspace.to_string_lossy().to_string(),
        repository: "unknown-repository".to_string(),
        branch: "unknown".to_string(),
        remote: "local".to_string(),
    };
    let status = crate::thread_api::GitStatusDto {
        dirty: false,
        ahead_by: 0,
        behind_by: 0,
    };

    ResolvedGitState {
        snapshot_status: GitStatusDto {
            workspace: repository_context.workspace.clone(),
            repository: repository_context.repository.clone(),
            branch: repository_context.branch.clone(),
            remote: None,
            dirty: false,
            ahead_by: 0,
            behind_by: 0,
        },
        response: GitStatusResponse {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: thread_id.to_string(),
            repository: repository_context,
            status,
        },
        branch: "unknown".to_string(),
        remote_name: None,
    }
}

fn is_not_git_repository_error(error: &str) -> bool {
    error.contains("not a git repository")
}

fn run_git<I, S>(workspace: &Path, args: I) -> Result<String, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let args = args
        .into_iter()
        .map(|value| value.as_ref().to_string())
        .collect::<Vec<_>>();
    let output = Command::new("git")
        .args(&args)
        .current_dir(workspace)
        .output()
        .map_err(|error| format!("Failed to run git {}: {error}", args.join(" ")))?;

    if output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return Ok(stdout);
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let detail = if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        format!(
            "git {} exited with status {}",
            args.join(" "),
            output.status
        )
    };
    Err(detail)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    use shared_contracts::ThreadStatus;

    use super::{execute_branch_switch, read_git_state, read_git_state_for_status};

    #[test]
    fn read_git_state_rejects_non_repo_workspace() {
        let dir = unique_temp_dir("non-repo");
        let error = read_git_state(dir.to_string_lossy().as_ref(), "thread-1")
            .expect_err("non-repo workspace should fail");

        assert!(error.contains("not a git repository"));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn read_git_state_for_status_returns_placeholder_for_non_repo_workspace() {
        let dir = unique_temp_dir("non-repo-status");
        let state = read_git_state_for_status(dir.to_string_lossy().as_ref(), "thread-1")
            .expect("non-repo workspace should degrade into unavailable git status");

        assert_eq!(state.response.repository.workspace, dir.to_string_lossy());
        assert_eq!(state.response.repository.repository, "unknown-repository");
        assert_eq!(state.response.repository.branch, "unknown");
        assert_eq!(state.response.repository.remote, "local");
        assert!(!state.response.status.dirty);
        assert_eq!(state.response.status.ahead_by, 0);
        assert_eq!(state.response.status.behind_by, 0);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn branch_switch_requires_existing_local_branch() {
        let repo = init_repo("missing-branch");
        let error = execute_branch_switch(
            repo.to_string_lossy().as_ref(),
            "thread-1",
            "release/does-not-exist",
            ThreadStatus::Idle,
            "2026-03-22T10:00:00Z",
        )
        .expect_err("missing branch should fail");

        assert!(
            error.contains("Needed a single revision")
                || error.contains("not a valid object name")
                || error.contains("unknown revision or path")
                || error.contains("bad revision"),
            "unexpected git error: {error}"
        );
        let _ = fs::remove_dir_all(repo.parent().expect("repo should have parent"));
    }

    fn init_repo(label: &str) -> PathBuf {
        let root = unique_temp_dir(label);
        let repo = root.join("repo");
        fs::create_dir_all(&repo).expect("repo dir should exist");
        run_git_ok(&repo, ["init"]);
        run_git_ok(&repo, ["config", "user.name", "Codex"]);
        run_git_ok(&repo, ["config", "user.email", "codex@example.com"]);
        run_git_ok(&repo, ["branch", "-M", "main"]);
        fs::write(repo.join("README.md"), "initial\n").expect("readme should write");
        run_git_ok(&repo, ["add", "."]);
        run_git_ok(&repo, ["commit", "-m", "initial"]);
        repo
    }

    fn unique_temp_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "bridge-controls-{label}-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock should move forward")
                .as_nanos()
        ));
        fs::create_dir_all(&path).expect("temp dir should exist");
        path
    }

    fn run_git_ok(cwd: &Path, args: impl IntoIterator<Item = impl AsRef<str>>) {
        let args = args
            .into_iter()
            .map(|value| value.as_ref().to_string())
            .collect::<Vec<_>>();
        let output = Command::new("git")
            .args(&args)
            .current_dir(cwd)
            .output()
            .expect("git command should run");
        assert!(
            output.status.success(),
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
