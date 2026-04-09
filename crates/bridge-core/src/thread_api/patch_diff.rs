use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
struct ApplyPatchFile {
    path: String,
    output_path: String,
    change_type: ApplyPatchChangeType,
    hunks: Vec<ApplyPatchHunk>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ApplyPatchChangeType {
    Modified,
    Added,
    Deleted,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ApplyPatchHunk {
    lines: Vec<ApplyPatchLine>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ApplyPatchLine {
    kind: ApplyPatchLineKind,
    text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ApplyPatchLineKind {
    Context,
    Addition,
    Deletion,
}

pub(super) fn resolve_apply_patch_to_unified_diff(
    patch_text: &str,
    workspace_path: Option<&str>,
) -> Option<String> {
    if !patch_text.contains("*** Begin Patch") {
        return None;
    }

    let patch_files = parse_apply_patch(patch_text);
    if patch_files.is_empty() {
        return None;
    }

    let mut rendered_files = Vec::new();
    for patch_file in patch_files {
        let rendered =
            render_resolved_apply_patch_file_as_unified_diff(&patch_file, workspace_path)?;
        rendered_files.push(rendered);
    }

    Some(rendered_files.join("\n"))
}

fn parse_apply_patch(patch_text: &str) -> Vec<ApplyPatchFile> {
    let mut files = Vec::new();
    let mut current_file: Option<ApplyPatchFile> = None;
    let mut current_hunk: Option<ApplyPatchHunk> = None;

    fn finish_hunk(
        current_file: &mut Option<ApplyPatchFile>,
        current_hunk: &mut Option<ApplyPatchHunk>,
    ) {
        if let Some(hunk) = current_hunk.take()
            && let Some(file) = current_file.as_mut()
            && !hunk.lines.is_empty()
        {
            file.hunks.push(hunk);
        }
    }

    fn finish_file(
        files: &mut Vec<ApplyPatchFile>,
        current_file: &mut Option<ApplyPatchFile>,
        current_hunk: &mut Option<ApplyPatchHunk>,
    ) {
        finish_hunk(current_file, current_hunk);
        if let Some(file) = current_file.take() {
            files.push(file);
        }
    }

    for raw_line in patch_text.lines() {
        if raw_line == "*** Begin Patch"
            || raw_line == "*** End Patch"
            || raw_line == "*** End of File"
        {
            continue;
        }

        if let Some(path) = raw_line.strip_prefix("*** Update File: ") {
            finish_file(&mut files, &mut current_file, &mut current_hunk);
            let normalized_path = path.trim().to_string();
            current_file = Some(ApplyPatchFile {
                output_path: normalized_path.clone(),
                path: normalized_path,
                change_type: ApplyPatchChangeType::Modified,
                hunks: Vec::new(),
            });
            continue;
        }

        if let Some(path) = raw_line.strip_prefix("*** Add File: ") {
            finish_file(&mut files, &mut current_file, &mut current_hunk);
            let normalized_path = path.trim().to_string();
            current_file = Some(ApplyPatchFile {
                output_path: normalized_path.clone(),
                path: normalized_path,
                change_type: ApplyPatchChangeType::Added,
                hunks: Vec::new(),
            });
            continue;
        }

        if let Some(path) = raw_line.strip_prefix("*** Delete File: ") {
            finish_file(&mut files, &mut current_file, &mut current_hunk);
            let normalized_path = path.trim().to_string();
            current_file = Some(ApplyPatchFile {
                output_path: normalized_path.clone(),
                path: normalized_path,
                change_type: ApplyPatchChangeType::Deleted,
                hunks: Vec::new(),
            });
            continue;
        }

        if let Some(path) = raw_line.strip_prefix("*** Move to: ") {
            if let Some(file) = current_file.as_mut() {
                file.output_path = path.trim().to_string();
            }
            continue;
        }

        if raw_line.starts_with("@@") {
            finish_hunk(&mut current_file, &mut current_hunk);
            current_hunk = Some(ApplyPatchHunk { lines: Vec::new() });
            continue;
        }

        let Some(file) = current_file.as_ref() else {
            continue;
        };
        let _ = file;

        let kind = if raw_line.starts_with('+') {
            Some(ApplyPatchLineKind::Addition)
        } else if raw_line.starts_with('-') {
            Some(ApplyPatchLineKind::Deletion)
        } else if raw_line.starts_with(' ') || raw_line.is_empty() {
            Some(ApplyPatchLineKind::Context)
        } else {
            None
        };

        if let Some(kind) = kind {
            let text = if raw_line.is_empty() {
                String::new()
            } else {
                raw_line[1..].to_string()
            };
            current_hunk
                .get_or_insert_with(|| ApplyPatchHunk { lines: Vec::new() })
                .lines
                .push(ApplyPatchLine { kind, text });
        }
    }

    finish_file(&mut files, &mut current_file, &mut current_hunk);
    files
}

fn render_resolved_apply_patch_file_as_unified_diff(
    patch_file: &ApplyPatchFile,
    workspace_path: Option<&str>,
) -> Option<String> {
    let old_lines = match patch_file.change_type {
        ApplyPatchChangeType::Added => Vec::new(),
        ApplyPatchChangeType::Modified | ApplyPatchChangeType::Deleted => {
            read_workspace_lines(workspace_path, &patch_file.path)?
        }
    };

    let mut rendered = Vec::new();
    rendered.push(format!(
        "diff --git a/{} b/{}",
        patch_file.path, patch_file.output_path
    ));
    rendered.push(match patch_file.change_type {
        ApplyPatchChangeType::Added => "--- /dev/null".to_string(),
        ApplyPatchChangeType::Modified | ApplyPatchChangeType::Deleted => {
            format!("--- a/{}", patch_file.path)
        }
    });
    rendered.push(match patch_file.change_type {
        ApplyPatchChangeType::Deleted => "+++ /dev/null".to_string(),
        ApplyPatchChangeType::Modified | ApplyPatchChangeType::Added => {
            format!("+++ b/{}", patch_file.output_path)
        }
    });

    if patch_file.hunks.is_empty() {
        match patch_file.change_type {
            ApplyPatchChangeType::Deleted => {
                let deleted_count = old_lines.len();
                if deleted_count > 0 {
                    rendered.push(format!("@@ -1,{} +0,0 @@", deleted_count));
                    for line in &old_lines {
                        rendered.push(format!("-{line}"));
                    }
                }
                return Some(rendered.join("\n"));
            }
            ApplyPatchChangeType::Added | ApplyPatchChangeType::Modified => {
                return None;
            }
        }
    }

    let mut search_start = 0_usize;
    let mut line_delta: isize = 0;
    for hunk in &patch_file.hunks {
        let old_pattern = hunk
            .lines
            .iter()
            .filter(|line| line.kind != ApplyPatchLineKind::Addition)
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        let match_index = match patch_file.change_type {
            ApplyPatchChangeType::Added => 0,
            ApplyPatchChangeType::Modified | ApplyPatchChangeType::Deleted => {
                locate_hunk_in_old_lines(&old_lines, &old_pattern, search_start)?
            }
        };

        let old_count = hunk
            .lines
            .iter()
            .filter(|line| line.kind != ApplyPatchLineKind::Addition)
            .count();
        let new_count = hunk
            .lines
            .iter()
            .filter(|line| line.kind != ApplyPatchLineKind::Deletion)
            .count();

        let old_start = match patch_file.change_type {
            ApplyPatchChangeType::Added => 0,
            ApplyPatchChangeType::Modified | ApplyPatchChangeType::Deleted => match_index + 1,
        };
        let new_start = match patch_file.change_type {
            ApplyPatchChangeType::Added => 1,
            ApplyPatchChangeType::Modified | ApplyPatchChangeType::Deleted => {
                (match_index as isize + line_delta + 1).max(0) as usize
            }
        };

        rendered.push(format!(
            "@@ -{},{} +{},{} @@",
            old_start, old_count, new_start, new_count
        ));
        for line in &hunk.lines {
            let prefix = match line.kind {
                ApplyPatchLineKind::Context => ' ',
                ApplyPatchLineKind::Addition => '+',
                ApplyPatchLineKind::Deletion => '-',
            };
            rendered.push(format!("{prefix}{}", line.text));
        }

        search_start = match_index.saturating_add(old_count);
        line_delta += new_count as isize - old_count as isize;
    }

    Some(rendered.join("\n"))
}

fn read_workspace_lines(workspace_path: Option<&str>, raw_path: &str) -> Option<Vec<String>> {
    let resolved_path = resolve_workspace_file_path(workspace_path, raw_path)?;
    let contents = fs::read_to_string(&resolved_path).ok()?;
    Some(contents.lines().map(normalize_line_ending).collect())
}

fn resolve_workspace_file_path(workspace_path: Option<&str>, raw_path: &str) -> Option<PathBuf> {
    let path = PathBuf::from(raw_path.trim());
    if path.is_absolute() {
        return Some(path);
    }

    let workspace = workspace_path?.trim();
    if workspace.is_empty() {
        return None;
    }

    Some(Path::new(workspace).join(path))
}

fn normalize_line_ending(line: &str) -> String {
    line.strip_suffix('\r').unwrap_or(line).to_string()
}

fn locate_hunk_in_old_lines(
    old_lines: &[String],
    old_pattern: &[&str],
    search_start: usize,
) -> Option<usize> {
    if old_pattern.is_empty() {
        return Some(search_start.min(old_lines.len()));
    }

    if old_pattern.len() > old_lines.len() {
        return None;
    }

    let normalized_pattern = old_pattern
        .iter()
        .map(|line| normalize_line_ending(line))
        .collect::<Vec<_>>();

    let max_start = old_lines.len().saturating_sub(normalized_pattern.len());
    for index in search_start..=max_start {
        if old_lines[index..index + normalized_pattern.len()]
            .iter()
            .zip(normalized_pattern.iter())
            .all(|(left, right)| left == right)
        {
            return Some(index);
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::resolve_apply_patch_to_unified_diff;

    #[test]
    fn renders_added_file_patch_as_unified_diff() {
        let temp_dir =
            std::env::temp_dir().join(format!("thread-api-patch-diff-{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp_dir);
        fs::create_dir_all(&temp_dir).expect("temp dir should exist");

        let patch = "\
*** Begin Patch
*** Add File: notes.txt
@@
+hello
+world
*** End Patch
";

        let diff = resolve_apply_patch_to_unified_diff(patch, Some(temp_dir.to_str().unwrap()))
            .expect("patch should render");

        assert!(diff.contains("diff --git a/notes.txt b/notes.txt"));
        assert!(diff.contains("--- /dev/null"));
        assert!(diff.contains("+++ b/notes.txt"));
        assert!(diff.contains("+hello"));
        assert!(diff.contains("+world"));
    }

    #[test]
    fn renders_deleted_file_without_hunks_from_workspace() {
        let temp_dir = std::env::temp_dir().join(format!(
            "thread-api-patch-diff-delete-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&temp_dir);
        fs::create_dir_all(&temp_dir).expect("temp dir should exist");
        fs::write(temp_dir.join("notes.txt"), "hello\nworld\n").expect("fixture should write");

        let patch = "\
*** Begin Patch
*** Delete File: notes.txt
*** End Patch
";

        let diff = resolve_apply_patch_to_unified_diff(patch, Some(temp_dir.to_str().unwrap()))
            .expect("delete patch should render");

        assert!(diff.contains("--- a/notes.txt"));
        assert!(diff.contains("+++ /dev/null"));
        assert!(diff.contains("-hello"));
        assert!(diff.contains("-world"));
    }
}
