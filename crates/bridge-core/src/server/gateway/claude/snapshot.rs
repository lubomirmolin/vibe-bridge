use super::super::mapping::{derive_repository_name_from_cwd, derive_repository_name_from_path};
use super::super::*;

pub(super) fn build_claude_placeholder_snapshot(
    thread_id: &str,
    workspace: &str,
) -> ThreadSnapshotDto {
    let timestamp = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let git_context = detect_git_context(workspace);
    let repository = git_context.repository.clone();
    let branch = git_context.branch.clone();
    ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: thread_id.to_string(),
            native_thread_id: native_thread_id_for_provider(thread_id, ProviderKind::ClaudeCode)
                .unwrap_or(thread_id)
                .to_string(),
            provider: ProviderKind::ClaudeCode,
            client: shared_contracts::ThreadClientKind::Bridge,
            title: "New thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: workspace.to_string(),
            repository: repository.clone(),
            branch: branch.clone(),
            created_at: timestamp.clone(),
            updated_at: timestamp,
            source: "bridge".to_string(),
            access_mode: AccessMode::ControlWithApprovals,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: Vec::new(),
        approvals: Vec::new(),
        git_status: Some(GitStatusDto {
            workspace: workspace.to_string(),
            repository,
            branch,
            remote: git_context.remote,
            dirty: false,
            ahead_by: 0,
            behind_by: 0,
        }),
        workflow_state: None,
        pending_user_input: None,
    }
}

#[derive(Debug, Clone)]
struct WorkspaceGitContext {
    repository: String,
    branch: String,
    remote: Option<String>,
}

fn detect_git_context(workspace: &str) -> WorkspaceGitContext {
    let repository = run_git_output(workspace, ["rev-parse", "--show-toplevel"])
        .ok()
        .as_deref()
        .and_then(derive_repository_name_from_path)
        .or_else(|| derive_repository_name_from_cwd(workspace))
        .unwrap_or_else(|| "unknown-repository".to_string());
    let branch = run_git_output(workspace, ["rev-parse", "--abbrev-ref", "HEAD"])
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    let remote = run_git_output(workspace, ["remote", "get-url", "origin"])
        .ok()
        .filter(|value| !value.trim().is_empty());

    WorkspaceGitContext {
        repository,
        branch,
        remote,
    }
}

fn run_git_output<I, S>(workspace: &str, args: I) -> Result<String, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let output = Command::new("git")
        .arg("-C")
        .arg(workspace)
        .args(args)
        .output()
        .map_err(|error| format!("failed to run git: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub(crate) fn claude_session_archive_path(workspace: &str, session_id: &str) -> Option<PathBuf> {
    let claude_home = std::env::var_os("CLAUDE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".claude")))?;
    Some(
        claude_home
            .join("projects")
            .join(claude_project_slug(workspace))
            .join(format!("{session_id}.jsonl")),
    )
}

pub(crate) fn claude_project_slug(workspace: &str) -> String {
    workspace
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
                ch
            } else {
                '-'
            }
        })
        .collect()
}
