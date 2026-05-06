use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags};
use serde_json::Value;

const DEFAULT_PROVIDER: &str = "openai";
const PAGE_SIZE: usize = 50;
const SESSION_DIRS: &[(&str, VisibilityScope)] = &[
    ("sessions", VisibilityScope::Sessions),
    ("archived_sessions", VisibilityScope::ArchivedSessions),
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VisibilityReport {
    pub codex_dir: PathBuf,
    pub config_provider: ConfigProvider,
    pub rollout: ScopedProviderCounts,
    pub encrypted_content: ScopedProviderCounts,
    pub sqlite: SqliteVisibility,
    pub global_state: GlobalStateVisibility,
    pub project_visibility: Vec<ProjectVisibility>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigProvider {
    pub provider: String,
    pub implicit: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScopedProviderCounts {
    pub sessions: BTreeMap<String, usize>,
    pub archived_sessions: BTreeMap<String, usize>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SqliteVisibility {
    pub present: bool,
    pub unreadable: bool,
    pub error: Option<String>,
    pub sessions: BTreeMap<String, usize>,
    pub archived_sessions: BTreeMap<String, usize>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GlobalStateVisibility {
    pub present: bool,
    pub unreadable: bool,
    pub error: Option<String>,
    pub workspace_roots: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectVisibility {
    pub root: String,
    pub interactive_threads: usize,
    pub first_page_threads: usize,
    pub exact_cwd_matches: usize,
    pub verbatim_cwd_rows: usize,
    pub rank_preview: String,
    pub provider_counts: BTreeMap<String, usize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum VisibilityScope {
    Sessions,
    ArchivedSessions,
}

#[derive(Debug, Clone)]
struct RankedThread {
    cwd: String,
    model_provider: String,
    rank: usize,
    normalized_cwd: Option<String>,
}

pub fn build_visibility_report(codex_dir: &Path) -> VisibilityReport {
    let mut warnings = Vec::new();
    let config_provider = read_config_provider(codex_dir, &mut warnings);
    let (rollout, encrypted_content) = read_rollout_visibility(codex_dir, &mut warnings);
    let sqlite = read_sqlite_visibility(codex_dir, &mut warnings);
    let global_state = read_global_state_visibility(codex_dir, &mut warnings);
    let project_visibility = if sqlite.present && !sqlite.unreadable {
        read_project_visibility(codex_dir, &global_state.workspace_roots, &mut warnings)
    } else {
        Vec::new()
    };

    add_provider_mismatch_warnings(
        "rollout",
        &config_provider.provider,
        &rollout,
        &mut warnings,
    );
    add_provider_mismatch_warnings(
        "SQLite",
        &config_provider.provider,
        &sqlite_scoped_counts(&sqlite),
        &mut warnings,
    );
    add_encrypted_content_warning(&config_provider.provider, &encrypted_content, &mut warnings);
    add_project_visibility_warnings(&project_visibility, &mut warnings);

    VisibilityReport {
        codex_dir: codex_dir.to_path_buf(),
        config_provider,
        rollout,
        encrypted_content,
        sqlite,
        global_state,
        project_visibility,
        warnings,
    }
}

pub fn render_visibility_report(report: &VisibilityReport) -> String {
    let mut lines = Vec::new();
    lines.push("Visibility diagnostics:".to_string());
    lines.push(format!(
        "  config provider: {}{}",
        report.config_provider.provider,
        if report.config_provider.implicit {
            " (implicit default)"
        } else {
            ""
        }
    ));

    lines.push("  rollout providers:".to_string());
    lines.push(format!(
        "    sessions: {}",
        format_counts(&report.rollout.sessions)
    ));
    lines.push(format!(
        "    archived_sessions: {}",
        format_counts(&report.rollout.archived_sessions)
    ));
    lines.push(format!(
        "    encrypted_content sessions: {}",
        format_counts(&report.encrypted_content.sessions)
    ));
    lines.push(format!(
        "    encrypted_content archived_sessions: {}",
        format_counts(&report.encrypted_content.archived_sessions)
    ));

    lines.push("  sqlite threads:".to_string());
    if !report.sqlite.present {
        lines.push("    state_5.sqlite: missing".to_string());
    } else if report.sqlite.unreadable {
        lines.push(format!(
            "    state_5.sqlite: unreadable{}",
            report
                .sqlite
                .error
                .as_ref()
                .map(|error| format!(" ({error})"))
                .unwrap_or_default()
        ));
    } else {
        lines.push(format!(
            "    sessions: {}",
            format_counts(&report.sqlite.sessions)
        ));
        lines.push(format!(
            "    archived_sessions: {}",
            format_counts(&report.sqlite.archived_sessions)
        ));
    }

    lines.push("  global state:".to_string());
    if !report.global_state.present {
        lines.push("    .codex-global-state.json: missing".to_string());
    } else if report.global_state.unreadable {
        lines.push(format!(
            "    .codex-global-state.json: unreadable{}",
            report
                .global_state
                .error
                .as_ref()
                .map(|error| format!(" ({error})"))
                .unwrap_or_default()
        ));
    } else {
        lines.push(format!(
            "    workspace roots: {}",
            report.global_state.workspace_roots.len()
        ));
        for root in report.global_state.workspace_roots.iter().take(5) {
            lines.push(format!("      {root}"));
        }
        if report.global_state.workspace_roots.len() > 5 {
            lines.push(format!(
                "      (+{} more)",
                report.global_state.workspace_roots.len() - 5
            ));
        }
    }

    lines.push("  project visibility:".to_string());
    if report.project_visibility.is_empty() {
        lines.push("    (none)".to_string());
    } else {
        for project in &report.project_visibility {
            lines.push(format!(
                "    {}: interactive {}, first page {}/{}, ranks {}, exact cwd {}/{}, verbatim cwd {}, providers {}",
                project.root,
                project.interactive_threads,
                project.first_page_threads,
                PAGE_SIZE,
                if project.rank_preview.is_empty() {
                    "(none)"
                } else {
                    project.rank_preview.as_str()
                },
                project.exact_cwd_matches,
                project.interactive_threads,
                project.verbatim_cwd_rows,
                format_counts(&project.provider_counts)
            ));
        }
    }

    lines.push("  warnings:".to_string());
    if report.warnings.is_empty() {
        lines.push("    (none)".to_string());
    } else {
        for warning in &report.warnings {
            lines.push(format!("    {warning}"));
        }
    }

    format!("{}\n", lines.join("\n"))
}

fn read_config_provider(codex_dir: &Path, warnings: &mut Vec<String>) -> ConfigProvider {
    let config_path = codex_dir.join("config.toml");
    let Ok(contents) = fs::read_to_string(&config_path) else {
        return ConfigProvider {
            provider: DEFAULT_PROVIDER.to_string(),
            implicit: true,
        };
    };

    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if trimmed.starts_with('[') {
            break;
        }
        if let Some((name, value)) = trimmed.split_once('=') {
            if name.trim() == "model_provider" {
                if let Some(provider) = parse_quoted_value(value.trim()) {
                    return ConfigProvider {
                        provider,
                        implicit: false,
                    };
                }
                warnings
                    .push("config.toml has an unreadable root model_provider value.".to_string());
                break;
            }
        }
    }

    ConfigProvider {
        provider: DEFAULT_PROVIDER.to_string(),
        implicit: true,
    }
}

fn parse_quoted_value(value: &str) -> Option<String> {
    if value.len() >= 2 && value.starts_with('"') && value.ends_with('"') {
        Some(value[1..value.len() - 1].replace("\\\"", "\""))
    } else {
        None
    }
}

fn read_rollout_visibility(
    codex_dir: &Path,
    warnings: &mut Vec<String>,
) -> (ScopedProviderCounts, ScopedProviderCounts) {
    let mut provider_counts = ScopedProviderCounts::default();
    let mut encrypted_counts = ScopedProviderCounts::default();

    for (dir_name, scope) in SESSION_DIRS {
        let root = codex_dir.join(dir_name);
        if !root.exists() {
            continue;
        }
        let mut paths = Vec::new();
        collect_rollout_paths(&root, &mut paths, warnings);
        for path in paths {
            match scan_rollout_file(&path) {
                Ok(Some((provider, has_encrypted_content))) => {
                    increment_scoped_count(&mut provider_counts, *scope, &provider);
                    if has_encrypted_content {
                        increment_scoped_count(&mut encrypted_counts, *scope, &provider);
                    }
                }
                Ok(None) => {}
                Err(error) => warnings.push(format!(
                    "Unable to scan rollout file {}: {error}",
                    path.display()
                )),
            }
        }
    }

    (provider_counts, encrypted_counts)
}

fn collect_rollout_paths(root: &Path, paths: &mut Vec<PathBuf>, warnings: &mut Vec<String>) {
    let Ok(entries) = fs::read_dir(root) else {
        warnings.push(format!(
            "Unable to read rollout directory {}",
            root.display()
        ));
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(metadata) = entry.metadata() else {
            warnings.push(format!("Unable to inspect {}", path.display()));
            continue;
        };
        if metadata.is_dir() {
            collect_rollout_paths(&path, paths, warnings);
        } else if metadata.is_file()
            && path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("rollout-") && name.ends_with(".jsonl"))
        {
            paths.push(path);
        }
    }
}

fn scan_rollout_file(path: &Path) -> std::io::Result<Option<(String, bool)>> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    let mut first_line = String::new();
    if reader.read_line(&mut first_line)? == 0 {
        return Ok(None);
    }

    let Ok(first_record) = serde_json::from_str::<Value>(first_line.trim_end()) else {
        return Ok(None);
    };
    if first_record.get("type").and_then(Value::as_str) != Some("session_meta") {
        return Ok(None);
    }
    let Some(payload) = first_record.get("payload").and_then(Value::as_object) else {
        return Ok(None);
    };

    let provider = payload
        .get("model_provider")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("(missing)")
        .to_string();
    let mut has_encrypted_content = first_line.contains("encrypted_content");
    let mut line = String::new();
    while reader.read_line(&mut line)? != 0 {
        if line.contains("encrypted_content") {
            has_encrypted_content = true;
            break;
        }
        line.clear();
    }

    Ok(Some((provider, has_encrypted_content)))
}

fn read_sqlite_visibility(codex_dir: &Path, warnings: &mut Vec<String>) -> SqliteVisibility {
    let db_path = codex_dir.join("state_5.sqlite");
    if !db_path.exists() {
        warnings.push(
            "state_5.sqlite is missing; Desktop visibility cannot be fully diagnosed.".to_string(),
        );
        return SqliteVisibility::default();
    }

    let connection = match Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY) {
        Ok(connection) => connection,
        Err(error) => {
            let message = sqlite_error_label(&error);
            warnings.push(format!("state_5.sqlite is unreadable: {message}"));
            return SqliteVisibility {
                present: true,
                unreadable: true,
                error: Some(message),
                ..SqliteVisibility::default()
            };
        }
    };

    match read_sqlite_provider_counts(&connection) {
        Ok(mut visibility) => {
            visibility.present = true;
            visibility
        }
        Err(error) => {
            let message = sqlite_error_label(&error);
            warnings.push(format!("state_5.sqlite is unreadable: {message}"));
            SqliteVisibility {
                present: true,
                unreadable: true,
                error: Some(message),
                ..SqliteVisibility::default()
            }
        }
    }
}

fn read_sqlite_provider_counts(connection: &Connection) -> rusqlite::Result<SqliteVisibility> {
    let columns = table_columns(connection, "threads")?;
    if columns.is_empty() {
        return Err(rusqlite::Error::InvalidQuery);
    }
    let provider_expression = if columns.contains("model_provider") {
        "CASE WHEN model_provider IS NULL OR model_provider = '' THEN '(missing)' ELSE model_provider END"
    } else {
        "'(missing)'"
    };
    let archived_expression = if columns.contains("archived") {
        "archived"
    } else {
        "0"
    };
    let sql = format!(
        "SELECT {provider_expression} AS model_provider, {archived_expression} AS archived, COUNT(*) AS count FROM threads GROUP BY model_provider, archived ORDER BY archived, model_provider"
    );

    let mut stmt = connection.prepare(&sql)?;
    let mut rows = stmt.query([])?;
    let mut visibility = SqliteVisibility {
        present: true,
        ..SqliteVisibility::default()
    };
    while let Some(row) = rows.next()? {
        let provider: String = row.get(0)?;
        let archived: i64 = row.get(1)?;
        let count: i64 = row.get(2)?;
        let bucket = if archived == 0 {
            &mut visibility.sessions
        } else {
            &mut visibility.archived_sessions
        };
        bucket.insert(provider, count.max(0) as usize);
    }

    Ok(visibility)
}

fn read_global_state_visibility(
    codex_dir: &Path,
    warnings: &mut Vec<String>,
) -> GlobalStateVisibility {
    let state_path = codex_dir.join(".codex-global-state.json");
    let Ok(contents) = fs::read_to_string(&state_path) else {
        return GlobalStateVisibility::default();
    };

    let parsed = match serde_json::from_str::<Value>(&contents) {
        Ok(parsed) => parsed,
        Err(error) => {
            let message = error.to_string();
            warnings.push(format!(".codex-global-state.json is unreadable: {message}"));
            return GlobalStateVisibility {
                present: true,
                unreadable: true,
                error: Some(message),
                workspace_roots: Vec::new(),
            };
        }
    };

    GlobalStateVisibility {
        present: true,
        unreadable: false,
        error: None,
        workspace_roots: read_workspace_roots_from_global_state(&parsed),
    }
}

fn read_workspace_roots_from_global_state(state: &Value) -> Vec<String> {
    let mut roots = Vec::new();
    for key in [
        "project-order",
        "electron-saved-workspace-roots",
        "active-workspace-roots",
    ] {
        roots.extend(to_path_array(state.get(key)));
    }

    let mut seen = BTreeSet::new();
    let mut deduped = Vec::new();
    for root in roots
        .into_iter()
        .map(|root| to_desktop_workspace_path(&root))
    {
        let Some(comparable) = normalize_comparable_path(&root) else {
            continue;
        };
        if seen.insert(comparable) {
            deduped.push(root);
        }
    }
    deduped
}

fn to_path_array(value: Option<&Value>) -> Vec<String> {
    match value {
        Some(Value::Array(entries)) => entries
            .iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .collect(),
        Some(Value::String(value)) if !value.trim().is_empty() => vec![value.trim().to_string()],
        _ => Vec::new(),
    }
}

fn read_project_visibility(
    codex_dir: &Path,
    workspace_roots: &[String],
    warnings: &mut Vec<String>,
) -> Vec<ProjectVisibility> {
    if workspace_roots.is_empty() {
        return Vec::new();
    }

    let db_path = codex_dir.join("state_5.sqlite");
    let connection = match Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY) {
        Ok(connection) => connection,
        Err(error) => {
            warnings.push(format!(
                "Unable to read project visibility diagnostics: {}",
                sqlite_error_label(&error)
            ));
            return Vec::new();
        }
    };
    let ranked_threads = match read_ranked_threads(&connection) {
        Ok(threads) => threads,
        Err(error) => {
            warnings.push(format!(
                "Unable to read project visibility diagnostics: {}",
                sqlite_error_label(&error)
            ));
            return Vec::new();
        }
    };

    workspace_roots
        .iter()
        .filter_map(|root| {
            let normalized_root = normalize_comparable_path(root)?;
            let desktop_root = to_desktop_workspace_path(root);
            let matching = ranked_threads
                .iter()
                .filter(|thread| thread.normalized_cwd.as_deref() == Some(normalized_root.as_str()))
                .collect::<Vec<_>>();
            let mut provider_counts = BTreeMap::new();
            let mut ranks = Vec::new();
            let mut exact_cwd_matches = 0;
            let mut verbatim_cwd_rows = 0;
            for thread in &matching {
                *provider_counts
                    .entry(thread.model_provider.clone())
                    .or_insert(0) += 1;
                ranks.push(thread.rank);
                if thread.cwd == desktop_root {
                    exact_cwd_matches += 1;
                }
                if thread.cwd.starts_with(r"\\?\") {
                    verbatim_cwd_rows += 1;
                }
            }
            Some(ProjectVisibility {
                root: desktop_root,
                interactive_threads: matching.len(),
                first_page_threads: ranks.iter().filter(|rank| **rank <= PAGE_SIZE).count(),
                exact_cwd_matches,
                verbatim_cwd_rows,
                rank_preview: format_rank_preview(&ranks),
                provider_counts,
            })
        })
        .collect()
}

fn read_ranked_threads(connection: &Connection) -> rusqlite::Result<Vec<RankedThread>> {
    let columns = table_columns(connection, "threads")?;
    if !columns.contains("cwd") {
        return Ok(Vec::new());
    }

    let id_expression = if columns.contains("id") {
        "id"
    } else {
        "rowid"
    };
    let provider_expression = if columns.contains("model_provider") {
        "CASE WHEN model_provider IS NULL OR model_provider = '' THEN '(missing)' ELSE model_provider END"
    } else {
        "'(missing)'"
    };
    let time_expression = match (
        columns.contains("updated_at_ms"),
        columns.contains("updated_at"),
    ) {
        (true, true) => "COALESCE(updated_at_ms, updated_at * 1000, 0)",
        (true, false) => "COALESCE(updated_at_ms, 0)",
        (false, true) => "COALESCE(updated_at * 1000, 0)",
        (false, false) => "0",
    };
    let archived_filter = if columns.contains("archived") {
        "AND archived = 0"
    } else {
        ""
    };
    let first_user_filter = if columns.contains("first_user_message") {
        "AND first_user_message <> ''"
    } else {
        ""
    };
    let source_filter = if columns.contains("source") {
        "AND source IN ('cli', 'vscode')"
    } else {
        ""
    };

    let sql = format!(
        "SELECT {id_expression} AS id, cwd, {provider_expression} AS model_provider, {time_expression} AS sort_ts FROM threads WHERE cwd IS NOT NULL AND cwd <> '' {archived_filter} {first_user_filter} {source_filter} ORDER BY sort_ts DESC, id DESC"
    );
    let mut stmt = connection.prepare(&sql)?;
    let mut rows = stmt.query([])?;
    let mut ranked = Vec::new();
    while let Some(row) = rows.next()? {
        let cwd: String = row.get(1)?;
        let model_provider: String = row.get(2)?;
        ranked.push(RankedThread {
            normalized_cwd: normalize_comparable_path(&cwd),
            cwd,
            model_provider,
            rank: ranked.len() + 1,
        });
    }
    Ok(ranked)
}

fn table_columns(connection: &Connection, table_name: &str) -> rusqlite::Result<BTreeSet<String>> {
    let escaped = table_name.replace('"', "\"\"");
    let mut stmt = connection.prepare(&format!("PRAGMA table_info(\"{escaped}\")"))?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
    let mut columns = BTreeSet::new();
    for row in rows {
        columns.insert(row?);
    }
    Ok(columns)
}

fn increment_scoped_count(
    counts: &mut ScopedProviderCounts,
    scope: VisibilityScope,
    provider: &str,
) {
    let bucket = match scope {
        VisibilityScope::Sessions => &mut counts.sessions,
        VisibilityScope::ArchivedSessions => &mut counts.archived_sessions,
    };
    *bucket.entry(provider.to_string()).or_insert(0) += 1;
}

fn sqlite_scoped_counts(sqlite: &SqliteVisibility) -> ScopedProviderCounts {
    ScopedProviderCounts {
        sessions: sqlite.sessions.clone(),
        archived_sessions: sqlite.archived_sessions.clone(),
    }
}

fn add_provider_mismatch_warnings(
    label: &str,
    current_provider: &str,
    counts: &ScopedProviderCounts,
    warnings: &mut Vec<String>,
) {
    let providers = counts
        .sessions
        .keys()
        .chain(counts.archived_sessions.keys())
        .filter(|provider| provider.as_str() != current_provider)
        .filter(|provider| provider.as_str() != "(missing)")
        .cloned()
        .collect::<BTreeSet<_>>();
    if !providers.is_empty() {
        warnings.push(format!(
            "{label} metadata contains provider(s) other than current provider {current_provider}: {}.",
            providers.into_iter().collect::<Vec<_>>().join(", ")
        ));
    }
}

fn add_encrypted_content_warning(
    current_provider: &str,
    counts: &ScopedProviderCounts,
    warnings: &mut Vec<String>,
) {
    let providers = counts
        .sessions
        .keys()
        .chain(counts.archived_sessions.keys())
        .filter(|provider| provider.as_str() != current_provider)
        .cloned()
        .collect::<BTreeSet<_>>();
    if providers.is_empty() {
        return;
    }

    let total =
        counts.sessions.values().sum::<usize>() + counts.archived_sessions.values().sum::<usize>();
    warnings.push(format!(
        "{total} rollout file(s) contain encrypted_content from provider(s) {}. A metadata repair may restore list visibility, but continuing or compacting those histories across provider/account boundaries can still fail with invalid_encrypted_content.",
        providers.into_iter().collect::<Vec<_>>().join(", ")
    ));
}

fn add_project_visibility_warnings(projects: &[ProjectVisibility], warnings: &mut Vec<String>) {
    for project in projects {
        if project.interactive_threads > 0 && project.first_page_threads == 0 {
            warnings.push(format!(
                "{} has {} interactive thread(s), but none are in the Desktop first page of {} recent threads.",
                project.root, project.interactive_threads, PAGE_SIZE
            ));
        }
        if project.interactive_threads > 0
            && project.exact_cwd_matches < project.interactive_threads
            && project.verbatim_cwd_rows > 0
        {
            warnings.push(format!(
                "{} has {} extended \\\\?\\ cwd row(s); Desktop workspace roots may not match those paths exactly.",
                project.root, project.verbatim_cwd_rows
            ));
        }
    }
}

fn format_counts(counts: &BTreeMap<String, usize>) -> String {
    if counts.is_empty() {
        return "(none)".to_string();
    }
    counts
        .iter()
        .map(|(provider, count)| format!("{provider}: {count}"))
        .collect::<Vec<_>>()
        .join(", ")
}

fn format_rank_preview(ranks: &[usize]) -> String {
    if ranks.is_empty() {
        return String::new();
    }
    if ranks.len() <= 8 {
        return ranks
            .iter()
            .map(usize::to_string)
            .collect::<Vec<_>>()
            .join(",");
    }
    let mut parts = ranks
        .iter()
        .take(4)
        .map(usize::to_string)
        .collect::<Vec<_>>();
    parts.push("...".to_string());
    parts.extend(
        ranks
            .iter()
            .rev()
            .take(2)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .map(usize::to_string),
    );
    parts.join(",")
}

fn to_desktop_workspace_path(value: &str) -> String {
    let trimmed = value.trim();
    if let Some(rest) = trimmed
        .strip_prefix(r"\\?\UNC\")
        .or_else(|| trimmed.strip_prefix(r"\\?\unc\"))
    {
        return format!(r"\\{}", rest).replace('/', r"\");
    }
    if let Some(rest) = trimmed.strip_prefix(r"\\?\") {
        return rest.replace('/', r"\");
    }
    trimmed.to_string()
}

fn normalize_comparable_path(value: &str) -> Option<String> {
    let mut normalized = value.trim().to_string();
    if normalized.is_empty() {
        return None;
    }
    normalized = to_desktop_workspace_path(&normalized).replace('/', r"\");
    while normalized.ends_with('\\') && !is_drive_root(&normalized) {
        normalized.pop();
    }
    if normalized.len() == 2 && normalized.as_bytes()[1] == b':' {
        normalized.push('\\');
    }
    Some(normalized.to_ascii_lowercase())
}

fn is_drive_root(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 3 && bytes[1] == b':' && bytes[2] == b'\\'
}

fn sqlite_error_label(error: &rusqlite::Error) -> String {
    let message = error.to_string();
    let lower = message.to_ascii_lowercase();
    if lower.contains("database disk image is malformed")
        || lower.contains("file is not a database")
        || lower.contains("not a database")
        || lower.contains("malformed")
    {
        "malformed or unreadable".to_string()
    } else if lower.contains("database is locked") || lower.contains("busy") {
        "currently in use".to_string()
    } else {
        message
    }
}
