//! Deterministic, bounded working-set plans for portable agent warmth.

use crate::fast_index::INDEX_FORMAT_VERSION;
use crate::shards::SHARD_MANIFEST_FORMAT_VERSION;
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

pub const WARMTH_PLAN_VERSION: u32 = 1;
pub const MAX_WARMTH_PLAN_PATHS: usize = 4096;
pub const MAX_WARMTH_PLAN_BYTES: u64 = 8 * 1024 * 1024 * 1024;
pub const MAX_WARMTH_CANDIDATES: usize = 65_536;
pub const MAX_WARMTH_SHARD_FILES: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WarmthPlanReason {
    DirectSearch,
    Related,
    RepoMap,
    Heat,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WarmthCandidate {
    pub path: String,
    pub reason: WarmthPlanReason,
    pub rank: u32,
    #[serde(default)]
    pub heat: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WarmthPlanRequest {
    pub repo: PathBuf,
    pub query: String,
    pub required_revision: Option<String>,
    pub max_paths: usize,
    pub max_bytes: u64,
    pub shard_files: Vec<String>,
    pub candidates: Vec<WarmthCandidate>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WarmthPlanEntry {
    pub path: String,
    pub size_bytes: u64,
    pub reasons: Vec<WarmthPlanReason>,
    pub best_rank: u32,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub heat: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WarmthPlan {
    pub plan_version: u32,
    pub repository_root: PathBuf,
    pub source_revision: String,
    pub source_tree: String,
    pub orient_version: String,
    pub index_format_version: u32,
    pub shard_manifest_format_version: u32,
    pub query: String,
    pub max_paths: usize,
    pub max_bytes: u64,
    pub shard_files: Vec<String>,
    pub prefetch: Vec<WarmthPlanEntry>,
    pub total_prefetch_bytes: u64,
    pub truncated: bool,
    pub rejected_candidates: usize,
}

#[derive(Debug)]
struct SelectedCandidate {
    path: String,
    size_bytes: u64,
    reasons: Vec<WarmthPlanReason>,
    best_rank: u32,
    heat: u64,
}

pub fn build_warmth_plan(request: WarmthPlanRequest) -> Result<WarmthPlan> {
    validate_budgets(&request)?;
    if request.candidates.len() > MAX_WARMTH_CANDIDATES {
        bail!("warmth candidate count exceeds {MAX_WARMTH_CANDIDATES}");
    }
    if request.shard_files.len() > MAX_WARMTH_SHARD_FILES {
        bail!("warmth shard file count exceeds {MAX_WARMTH_SHARD_FILES}");
    }

    let repository_root = request
        .repo
        .canonicalize()
        .with_context(|| format!("resolve repository {}", request.repo.display()))?;
    let source_revision = git_identity(&repository_root, "HEAD")?;
    let source_tree = git_identity(&repository_root, "HEAD^{tree}")?;
    if let Some(required) = request.required_revision.as_deref() {
        if required != source_revision {
            bail!(
                "required revision {required} does not match repository revision {source_revision}"
            );
        }
    }

    let mut rejected_candidates = 0usize;
    let mut candidates = BTreeMap::<String, SelectedCandidate>::new();
    for candidate in request.candidates {
        let Some(path) = normalize_relative_path(&candidate.path) else {
            rejected_candidates += 1;
            continue;
        };
        let source = repository_root.join(&path);
        let metadata = match fs::symlink_metadata(&source) {
            Ok(metadata) if metadata.file_type().is_file() => metadata,
            _ => {
                rejected_candidates += 1;
                continue;
            }
        };
        let canonical = match source.canonicalize() {
            Ok(canonical) if canonical.starts_with(&repository_root) => canonical,
            _ => {
                rejected_candidates += 1;
                continue;
            }
        };
        if canonical != source {
            rejected_candidates += 1;
            continue;
        }
        let normalized = path.to_string_lossy().replace('\\', "/");
        let entry = candidates
            .entry(normalized.clone())
            .or_insert_with(|| SelectedCandidate {
                path: normalized,
                size_bytes: metadata.len(),
                reasons: Vec::new(),
                best_rank: candidate.rank,
                heat: candidate.heat,
            });
        if !entry.reasons.contains(&candidate.reason) {
            entry.reasons.push(candidate.reason);
            entry.reasons.sort();
        }
        entry.best_rank = entry.best_rank.min(candidate.rank);
        entry.heat = entry.heat.max(candidate.heat);
    }

    let mut candidates = candidates.into_values().collect::<Vec<_>>();
    candidates.sort_by(|left, right| {
        candidate_priority(left)
            .cmp(&candidate_priority(right))
            .then_with(|| left.best_rank.cmp(&right.best_rank))
            .then_with(|| right.heat.cmp(&left.heat))
            .then_with(|| left.path.cmp(&right.path))
    });

    let candidate_count = candidates.len();
    let mut total_prefetch_bytes = 0u64;
    let mut prefetch = Vec::new();
    for candidate in candidates {
        if prefetch.len() == request.max_paths {
            break;
        }
        let Some(next_total) = total_prefetch_bytes.checked_add(candidate.size_bytes) else {
            continue;
        };
        if next_total > request.max_bytes {
            continue;
        }
        total_prefetch_bytes = next_total;
        prefetch.push(WarmthPlanEntry {
            path: candidate.path,
            size_bytes: candidate.size_bytes,
            reasons: candidate.reasons,
            best_rank: candidate.best_rank,
            heat: candidate.heat,
        });
    }

    let mut shard_files = request
        .shard_files
        .into_iter()
        .filter_map(|path| normalize_relative_path(&path))
        .map(|path| path.to_string_lossy().replace('\\', "/"))
        .collect::<Vec<_>>();
    shard_files.sort();
    shard_files.dedup();

    Ok(WarmthPlan {
        plan_version: WARMTH_PLAN_VERSION,
        repository_root,
        source_revision,
        source_tree,
        orient_version: env!("CARGO_PKG_VERSION").to_string(),
        index_format_version: INDEX_FORMAT_VERSION,
        shard_manifest_format_version: SHARD_MANIFEST_FORMAT_VERSION,
        query: request.query,
        max_paths: request.max_paths,
        max_bytes: request.max_bytes,
        shard_files,
        truncated: prefetch.len() < candidate_count,
        prefetch,
        total_prefetch_bytes,
        rejected_candidates,
    })
}

fn validate_budgets(request: &WarmthPlanRequest) -> Result<()> {
    if request.max_paths == 0
        || request.max_paths > MAX_WARMTH_PLAN_PATHS
        || request.max_bytes == 0
        || request.max_bytes > MAX_WARMTH_PLAN_BYTES
    {
        bail!(
            "warmth budget must be within 1..={MAX_WARMTH_PLAN_PATHS} paths and 1..={MAX_WARMTH_PLAN_BYTES} bytes"
        );
    }
    Ok(())
}

fn candidate_priority(candidate: &SelectedCandidate) -> WarmthPlanReason {
    candidate
        .reasons
        .iter()
        .copied()
        .min()
        .unwrap_or(WarmthPlanReason::Heat)
}

fn normalize_relative_path(value: &str) -> Option<PathBuf> {
    if value.is_empty() || value.contains('\0') {
        return None;
    }
    let path = Path::new(value);
    if path.is_absolute() {
        return None;
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => normalized.push(part),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    (!normalized.as_os_str().is_empty()).then_some(normalized)
}

fn git_identity(repo: &Path, revision: &str) -> Result<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["rev-parse", "--verify", revision])
        .output()
        .with_context(|| format!("run git in {}", repo.display()))?;
    if !output.status.success() {
        bail!(
            "resolve Git identity for {}: {}",
            repo.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let value = String::from_utf8(output.stdout)
        .context("Git identity was not UTF-8")?
        .trim()
        .to_string();
    if value.len() != 40 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("Git returned an invalid identity for {revision}");
    }
    Ok(value.to_ascii_lowercase())
}

fn is_zero(value: &u64) -> bool {
    *value == 0
}
