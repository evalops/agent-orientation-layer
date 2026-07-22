use orient::warmth::{WarmthCandidate, WarmthPlanReason, WarmthPlanRequest, build_warmth_plan};
use std::fs;
use std::path::Path;
use std::process::Command;

fn write(path: &Path, bytes: &[u8]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, bytes).unwrap();
}

fn git(repo: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?} failed");
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

fn repository() -> tempfile::TempDir {
    let repo = tempfile::tempdir().unwrap();
    git(repo.path(), &["init", "-q"]);
    git(repo.path(), &["config", "user.email", "orient@example.com"]);
    git(repo.path(), &["config", "user.name", "Orient Tests"]);
    write(&repo.path().join("src/direct.rs"), b"aaaa");
    write(&repo.path().join("src/related.rs"), b"bbbb");
    write(&repo.path().join("Cargo.toml"), b"cccc");
    write(&repo.path().join("docs/heat.md"), b"dddd");
    git(repo.path(), &["add", "."]);
    git(repo.path(), &["commit", "-qm", "fixture"]);
    repo
}

fn candidate(path: &str, reason: WarmthPlanReason, rank: u32) -> WarmthCandidate {
    WarmthCandidate {
        path: path.to_string(),
        reason,
        rank,
        heat: 0,
    }
}

#[test]
fn warmth_plan_is_deterministic_deduplicated_and_budgeted() {
    let repo = repository();
    let request = WarmthPlanRequest {
        repo: repo.path().to_path_buf(),
        query: "session token".to_string(),
        required_revision: None,
        max_paths: 2,
        max_bytes: 8,
        shard_files: vec!["manifest.json".into(), "repo.orient".into()],
        candidates: vec![
            candidate("docs/heat.md", WarmthPlanReason::Heat, 0),
            candidate("Cargo.toml", WarmthPlanReason::RepoMap, 0),
            candidate("src/related.rs", WarmthPlanReason::Related, 0),
            candidate("src/direct.rs", WarmthPlanReason::DirectSearch, 1),
            WarmthCandidate {
                path: "src/direct.rs".into(),
                reason: WarmthPlanReason::Heat,
                rank: 0,
                heat: 99,
            },
        ],
    };

    let first = build_warmth_plan(request.clone()).unwrap();
    let second = build_warmth_plan(request).unwrap();
    assert_eq!(first, second);
    assert_eq!(first.plan_version, 1);
    assert_eq!(first.prefetch.len(), 2);
    assert_eq!(first.prefetch[0].path, "src/direct.rs");
    assert_eq!(first.prefetch[1].path, "src/related.rs");
    assert_eq!(first.total_prefetch_bytes, 8);
    assert!(first.truncated);
    assert_eq!(first.rejected_candidates, 0);
    assert_eq!(
        first.prefetch[0].reasons,
        vec![WarmthPlanReason::DirectSearch, WarmthPlanReason::Heat]
    );
    assert_eq!(first.source_revision.len(), 40);
    assert_eq!(first.source_tree.len(), 40);
}

#[test]
fn warmth_plan_rejects_revision_mismatch_and_unsafe_candidates() {
    let repo = repository();
    let mut request = WarmthPlanRequest {
        repo: repo.path().to_path_buf(),
        query: String::new(),
        required_revision: Some("f".repeat(40)),
        max_paths: 8,
        max_bytes: 1024,
        shard_files: Vec::new(),
        candidates: vec![candidate("../secret", WarmthPlanReason::Heat, 0)],
    };
    let error = build_warmth_plan(request.clone()).unwrap_err().to_string();
    assert!(error.contains("required revision"), "{error}");

    request.required_revision = None;
    let plan = build_warmth_plan(request).unwrap();
    assert!(plan.prefetch.is_empty());
    assert_eq!(plan.rejected_candidates, 1);
}

#[test]
fn warmth_plan_empty_query_uses_generic_orientation_and_skips_links() {
    let repo = repository();
    #[cfg(unix)]
    std::os::unix::fs::symlink("direct.rs", repo.path().join("src/link.rs")).unwrap();

    let plan = build_warmth_plan(WarmthPlanRequest {
        repo: repo.path().to_path_buf(),
        query: String::new(),
        required_revision: None,
        max_paths: 4,
        max_bytes: 1024,
        shard_files: Vec::new(),
        candidates: vec![
            candidate("Cargo.toml", WarmthPlanReason::RepoMap, 0),
            candidate("src/link.rs", WarmthPlanReason::Heat, 0),
        ],
    })
    .unwrap();

    assert_eq!(plan.prefetch.len(), 1);
    assert_eq!(plan.prefetch[0].path, "Cargo.toml");
    assert_eq!(plan.rejected_candidates, 1);
}

#[test]
fn warmth_plan_rejects_zero_budgets() {
    let repo = repository();
    let error = build_warmth_plan(WarmthPlanRequest {
        repo: repo.path().to_path_buf(),
        query: String::new(),
        required_revision: None,
        max_paths: 0,
        max_bytes: 1,
        shard_files: Vec::new(),
        candidates: Vec::new(),
    })
    .unwrap_err()
    .to_string();
    assert!(error.contains("budget"), "{error}");
}
