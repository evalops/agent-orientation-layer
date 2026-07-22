//! Deterministic, bounded working-set plans for portable agent warmth.

use crate::fast_index::INDEX_FORMAT_VERSION;
use crate::repo_index::{RepoIndexer, RepoMapDetail};
use crate::shards::SHARD_MANIFEST_FORMAT_VERSION;
use crate::shards::warmth_shard_files_for_repo;
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
pub const MAX_WARMTH_QUERY_BYTES: usize = 8 * 1024;
pub const MAX_WARMTH_PATH_BYTES: usize = 4 * 1024;
pub const MAX_WARMTH_HEAT_BYTES: u64 = 8 * 1024 * 1024;
pub const MAX_SERIALIZED_WARMTH_PLAN_BYTES: usize = 32 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WarmthHeatObservation {
    pub path: String,
    pub count: u64,
}

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepositoryWarmthPlanRequest {
    pub repo: PathBuf,
    pub index_dir: Option<PathBuf>,
    pub query: String,
    pub required_revision: Option<String>,
    pub max_paths: usize,
    pub max_bytes: u64,
    pub heat: Vec<WarmthHeatObservation>,
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
    ranks: BTreeMap<WarmthPlanReason, u32>,
    heat: u64,
}

pub fn build_warmth_plan(request: WarmthPlanRequest) -> Result<WarmthPlan> {
    validate_budgets(&request)?;
    validate_text_bounds(&request.query, &request.candidates)?;
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
    if let Some(required) = request.required_revision.as_deref()
        && required != source_revision
    {
        bail!("required revision {required} does not match repository revision {source_revision}");
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
                ranks: BTreeMap::new(),
                heat: candidate.heat,
            });
        if !entry.reasons.contains(&candidate.reason) {
            entry.reasons.push(candidate.reason);
            entry.reasons.sort();
        }
        entry
            .ranks
            .entry(candidate.reason)
            .and_modify(|rank| *rank = (*rank).min(candidate.rank))
            .or_insert(candidate.rank);
        entry.heat = entry.heat.max(candidate.heat);
    }

    let mut candidates = candidates.into_values().collect::<Vec<_>>();
    candidates.sort_by(|left, right| {
        let left_reason = candidate_priority(left);
        let right_reason = candidate_priority(right);
        left_reason
            .cmp(&right_reason)
            .then_with(|| match left_reason {
                WarmthPlanReason::Heat => right.heat.cmp(&left.heat),
                _ => candidate_rank(left, left_reason).cmp(&candidate_rank(right, right_reason)),
            })
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
        let best_rank = candidate_rank(&candidate, candidate_priority(&candidate));
        prefetch.push(WarmthPlanEntry {
            path: candidate.path,
            size_bytes: candidate.size_bytes,
            reasons: candidate.reasons,
            best_rank,
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

    let plan = WarmthPlan {
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
    };
    if serde_json::to_vec(&plan)?.len() > MAX_SERIALIZED_WARMTH_PLAN_BYTES {
        bail!("serialized warmth plan exceeds {MAX_SERIALIZED_WARMTH_PLAN_BYTES} bytes");
    }
    Ok(plan)
}

pub fn build_repository_warmth_plan(request: RepositoryWarmthPlanRequest) -> Result<WarmthPlan> {
    validate_repository_request(&request)?;
    let repository_root = request
        .repo
        .canonicalize()
        .with_context(|| format!("resolve repository {}", request.repo.display()))?;
    ensure_git_clean(&repository_root, request.index_dir.as_deref())?;
    let source_revision = git_identity(&repository_root, "HEAD")?;
    let source_tree = git_identity(&repository_root, "HEAD^{tree}")?;
    if let Some(required) = request.required_revision.as_deref()
        && required != source_revision
    {
        bail!("required revision {required} does not match repository revision {source_revision}");
    }
    let index = RepoIndexer::new(&request.repo).build()?;
    let candidate_limit = request.max_paths.saturating_mul(4).clamp(16, 256);
    let mut candidates = Vec::new();
    if !request.query.trim().is_empty() {
        let results = index.search_code(&request.query, candidate_limit);
        for (rank, result) in results.iter().enumerate() {
            candidates.push(WarmthCandidate {
                path: result.path.clone(),
                reason: WarmthPlanReason::DirectSearch,
                rank: rank as u32,
                heat: 0,
            });
            for (related_rank, related) in
                index.related_files(&result.path, 4).into_iter().enumerate()
            {
                candidates.push(WarmthCandidate {
                    path: related.path,
                    reason: WarmthPlanReason::Related,
                    rank: (rank.saturating_mul(4).saturating_add(related_rank)) as u32,
                    heat: 0,
                });
            }
        }
    }

    let map = index.repo_map_with_detail(24, 24, RepoMapDetail::Compact);
    let map_paths = map
        .entrypoints
        .into_iter()
        .chain(map.test_files)
        .chain(map.manifest_files)
        .chain(map.important_files)
        .chain(map.top_symbols.into_iter().map(|symbol| symbol.path))
        .chain(map.related_files.into_iter().map(|file| file.path));
    for (rank, path) in map_paths.enumerate() {
        candidates.push(WarmthCandidate {
            path,
            reason: WarmthPlanReason::RepoMap,
            rank: rank as u32,
            heat: 0,
        });
    }
    for observation in request.heat {
        candidates.push(WarmthCandidate {
            path: observation.path,
            reason: WarmthPlanReason::Heat,
            rank: 0,
            heat: observation.count,
        });
    }

    let shard_files = request
        .index_dir
        .as_deref()
        .map(|index_dir| warmth_shard_files_for_repo(index_dir, &repository_root, &source_tree))
        .transpose()?
        .unwrap_or_default();
    ensure_git_clean(&repository_root, request.index_dir.as_deref())?;
    if git_identity(&repository_root, "HEAD")? != source_revision
        || git_identity(&repository_root, "HEAD^{tree}")? != source_tree
    {
        bail!("repository changed while building warmth plan");
    }
    build_warmth_plan(WarmthPlanRequest {
        repo: repository_root,
        query: request.query,
        required_revision: request.required_revision,
        max_paths: request.max_paths,
        max_bytes: request.max_bytes,
        shard_files,
        candidates,
    })
}

fn validate_repository_request(request: &RepositoryWarmthPlanRequest) -> Result<()> {
    let budget_request = WarmthPlanRequest {
        repo: request.repo.clone(),
        query: request.query.clone(),
        required_revision: request.required_revision.clone(),
        max_paths: request.max_paths,
        max_bytes: request.max_bytes,
        shard_files: Vec::new(),
        candidates: Vec::new(),
    };
    validate_budgets(&budget_request)?;
    if request.query.len() > MAX_WARMTH_QUERY_BYTES {
        bail!("warmth query exceeds {MAX_WARMTH_QUERY_BYTES} bytes");
    }
    if request.heat.len() > MAX_WARMTH_CANDIDATES {
        bail!("warmth heat observation count exceeds {MAX_WARMTH_CANDIDATES}");
    }
    if request
        .heat
        .iter()
        .any(|observation| observation.path.len() > MAX_WARMTH_PATH_BYTES)
    {
        bail!("warmth heat path exceeds {MAX_WARMTH_PATH_BYTES} bytes");
    }
    Ok(())
}

fn validate_text_bounds(query: &str, candidates: &[WarmthCandidate]) -> Result<()> {
    if query.len() > MAX_WARMTH_QUERY_BYTES {
        bail!("warmth query exceeds {MAX_WARMTH_QUERY_BYTES} bytes");
    }
    if candidates
        .iter()
        .any(|candidate| candidate.path.len() > MAX_WARMTH_PATH_BYTES)
    {
        bail!("warmth candidate path exceeds {MAX_WARMTH_PATH_BYTES} bytes");
    }
    Ok(())
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

fn candidate_rank(candidate: &SelectedCandidate, reason: WarmthPlanReason) -> u32 {
    candidate.ranks.get(&reason).copied().unwrap_or(u32::MAX)
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
    if !matches!(value.len(), 40 | 64) || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("Git returned an invalid identity for {revision}");
    }
    Ok(value.to_ascii_lowercase())
}

fn ensure_git_clean(repo: &Path, allowed_generated_dir: Option<&Path>) -> Result<()> {
    let refresh = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["update-index", "-q", "--refresh"])
        .status()
        .with_context(|| format!("refresh Git index in {}", repo.display()))?;
    if !refresh.success() {
        bail!("repository must be clean before building reusable warmth");
    }
    let tracked = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["diff-index", "--quiet", "HEAD", "--"])
        .status()
        .with_context(|| format!("inspect tracked Git state in {}", repo.display()))?;
    if !tracked.success() {
        bail!("repository must be clean before building reusable warmth");
    }
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["ls-files", "--others", "--exclude-standard", "-z"])
        .output()
        .with_context(|| format!("inspect untracked Git state in {}", repo.display()))?;
    if !output.status.success() {
        bail!("inspect untracked Git state in {} failed", repo.display());
    }
    let allowed = allowed_generated_dir.and_then(|path| path.canonicalize().ok());
    for raw_path in output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
    {
        let path = std::str::from_utf8(raw_path).context("untracked Git path was not UTF-8")?;
        let absolute = repo.join(path);
        if allowed
            .as_ref()
            .is_none_or(|allowed| !absolute.starts_with(allowed))
        {
            bail!("repository must be clean before building reusable warmth");
        }
    }
    Ok(())
}

fn is_zero(value: &u64) -> bool {
    *value == 0
}
