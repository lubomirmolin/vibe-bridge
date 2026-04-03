use super::*;

pub(super) fn resolve_latest_thread_change_diff(
    entries: &[ThreadTimelineEntryDto],
    path: Option<&str>,
) -> String {
    let normalized_path = path.map(str::trim).filter(|path| !path.is_empty());
    for entry in entries.iter().rev() {
        let Some(diff) = entry
            .payload
            .get("resolved_unified_diff")
            .and_then(Value::as_str)
            .or_else(|| entry.payload.get("output").and_then(Value::as_str))
        else {
            continue;
        };
        let summaries = parse_git_diff_file_summaries(diff);
        if summaries.is_empty() {
            continue;
        }
        if let Some(path) = normalized_path
            && summaries.iter().all(|file| file.path != path)
        {
            continue;
        }
        return diff.to_string();
    }
    String::new()
}

pub(super) fn resolve_workspace_diff(
    workspace: &str,
    path: Option<&str>,
) -> Result<(String, Option<String>), String> {
    let workspace = workspace.trim();
    if workspace.is_empty() {
        return Err("thread workspace is unavailable".to_string());
    }
    if !Path::new(workspace).exists() {
        return Err(format!("thread workspace does not exist: {workspace}"));
    }

    let revision = git_output(workspace, &["rev-parse", "HEAD"])
        .ok()
        .map(|value| value.trim().to_string());
    let mut unified_diff = git_output(
        workspace,
        &[
            "-c",
            "core.quotepath=false",
            "diff",
            "HEAD",
            "--find-renames",
            "--find-copies",
            "--binary",
            "--",
        ],
    )
    .or_else(|_| {
        git_output(
            workspace,
            &[
                "-c",
                "core.quotepath=false",
                "diff",
                "--cached",
                "--find-renames",
                "--find-copies",
                "--binary",
                "--",
            ],
        )
    })?;

    if let Some(path) = path.map(str::trim).filter(|path| !path.is_empty()) {
        unified_diff = git_output(
            workspace,
            &[
                "-c",
                "core.quotepath=false",
                "diff",
                "HEAD",
                "--find-renames",
                "--find-copies",
                "--binary",
                "--",
                path,
            ],
        )
        .or_else(|_| {
            git_output(
                workspace,
                &[
                    "-c",
                    "core.quotepath=false",
                    "diff",
                    "--cached",
                    "--find-renames",
                    "--find-copies",
                    "--binary",
                    "--",
                    path,
                ],
            )
        })?;
    }

    let mut untracked_files =
        git_output(workspace, &["ls-files", "--others", "--exclude-standard"])?
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .filter(|line| {
                path.map(str::trim)
                    .filter(|value| !value.is_empty())
                    .is_none_or(|selected| *line == selected)
            })
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>();
    untracked_files.sort();
    for untracked in untracked_files {
        if Path::new(workspace).join(&untracked).is_dir() {
            continue;
        }
        let diff = git_no_index_diff(workspace, "/dev/null", &untracked)?;
        if !unified_diff.is_empty() && !diff.is_empty() {
            unified_diff.push('\n');
        }
        unified_diff.push_str(diff.trim_end());
    }

    Ok((unified_diff.trim().to_string(), revision))
}

fn git_output(workspace: &str, args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .current_dir(workspace)
        .args(args)
        .output()
        .map_err(|error| format!("failed to execute git: {error}"))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn git_no_index_diff(workspace: &str, left: &str, right: &str) -> Result<String, String> {
    let output = Command::new("git")
        .current_dir(workspace)
        .args([
            "-c",
            "core.quotepath=false",
            "diff",
            "--no-index",
            "--binary",
            "--find-renames",
            "--find-copies",
            left,
            right,
        ])
        .output()
        .map_err(|error| format!("failed to execute git diff --no-index: {error}"))?;

    if output.status.success() || output.status.code() == Some(1) {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

pub(super) fn parse_git_diff_file_summaries(diff: &str) -> Vec<GitDiffFileSummaryDto> {
    let mut files = Vec::new();
    let mut current: Option<ParsedGitDiffSummary> = None;

    for line in diff.lines() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            if let Some(file) = current.take() {
                files.push(file.finish());
            }
            current = Some(ParsedGitDiffSummary::from_diff_git(rest));
            continue;
        }

        let Some(file) = current.as_mut() else {
            continue;
        };

        if let Some(path) = line.strip_prefix("--- ") {
            file.apply_old_marker(path.trim());
            continue;
        }
        if let Some(path) = line.strip_prefix("+++ ") {
            file.apply_new_marker(path.trim());
            continue;
        }
        if let Some(path) = line.strip_prefix("rename from ") {
            file.old_path = Some(path.trim().to_string());
            file.change_type = GitDiffChangeTypeDto::Renamed;
            continue;
        }
        if let Some(path) = line.strip_prefix("rename to ") {
            file.new_path = Some(path.trim().to_string());
            file.path = path.trim().to_string();
            file.change_type = GitDiffChangeTypeDto::Renamed;
            continue;
        }
        if let Some(path) = line.strip_prefix("copy from ") {
            file.old_path = Some(path.trim().to_string());
            file.change_type = GitDiffChangeTypeDto::Copied;
            continue;
        }
        if let Some(path) = line.strip_prefix("copy to ") {
            file.new_path = Some(path.trim().to_string());
            file.path = path.trim().to_string();
            file.change_type = GitDiffChangeTypeDto::Copied;
            continue;
        }
        if line.starts_with("new file mode ") {
            file.change_type = GitDiffChangeTypeDto::Added;
            continue;
        }
        if line.starts_with("deleted file mode ") {
            file.change_type = GitDiffChangeTypeDto::Deleted;
            continue;
        }
        if line.starts_with("old mode ") || line.starts_with("new mode ") {
            if file.change_type == GitDiffChangeTypeDto::Modified {
                file.change_type = GitDiffChangeTypeDto::TypeChanged;
            }
            continue;
        }
        if line.starts_with("Binary files ") || line.starts_with("GIT binary patch") {
            file.is_binary = true;
            continue;
        }
        if line.starts_with("@@ ") || line == "@@" {
            continue;
        }
        if line.starts_with('+') && !line.starts_with("+++") {
            file.additions += 1;
            continue;
        }
        if line.starts_with('-') && !line.starts_with("---") {
            file.deletions += 1;
        }
    }

    if let Some(file) = current.take() {
        files.push(file.finish());
    }

    files
}

#[derive(Debug)]
struct ParsedGitDiffSummary {
    path: String,
    old_path: Option<String>,
    new_path: Option<String>,
    change_type: GitDiffChangeTypeDto,
    additions: u32,
    deletions: u32,
    is_binary: bool,
}

impl ParsedGitDiffSummary {
    fn from_diff_git(rest: &str) -> Self {
        let mut parts = rest.split_whitespace();
        let old_path = parts.next().map(normalize_diff_path);
        let new_path = parts.next().map(normalize_diff_path);
        let path = new_path
            .clone()
            .or_else(|| old_path.clone())
            .unwrap_or_default();

        Self {
            path,
            old_path,
            new_path,
            change_type: GitDiffChangeTypeDto::Modified,
            additions: 0,
            deletions: 0,
            is_binary: false,
        }
    }

    fn apply_old_marker(&mut self, path: &str) {
        if path == "/dev/null" {
            self.change_type = GitDiffChangeTypeDto::Added;
            self.old_path = None;
            return;
        }
        self.old_path = Some(normalize_diff_path(path));
    }

    fn apply_new_marker(&mut self, path: &str) {
        if path == "/dev/null" {
            self.change_type = GitDiffChangeTypeDto::Deleted;
            self.new_path = None;
            return;
        }
        let normalized = normalize_diff_path(path);
        self.path = normalized.clone();
        self.new_path = Some(normalized);
    }

    fn finish(self) -> GitDiffFileSummaryDto {
        GitDiffFileSummaryDto {
            path: self.path,
            old_path: self.old_path,
            new_path: self.new_path,
            change_type: self.change_type,
            additions: self.additions,
            deletions: self.deletions,
            is_binary: self.is_binary,
        }
    }
}

fn normalize_diff_path(path: &str) -> String {
    path.trim()
        .trim_matches('"')
        .strip_prefix("a/")
        .or_else(|| path.trim().trim_matches('"').strip_prefix("b/"))
        .unwrap_or(path.trim().trim_matches('"'))
        .to_string()
}
