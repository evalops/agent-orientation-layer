#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${USER:-}" ]]; then
  user_home="$(eval echo "~${USER}")"
else
  user_home="${HOME}"
fi
export RUSTUP_HOME="${RUSTUP_HOME:-${user_home}/.rustup}"
export CARGO_HOME="${CARGO_HOME:-${user_home}/.cargo}"
export PATH="/etc/profiles/per-user/${USER:-}/bin:${CARGO_HOME}/bin:${user_home}/go/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"
cd "${BUILD_WORKSPACE_DIRECTORY:-$(pwd)}"
cargo build --release

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/orient-perf-gates.XXXXXX")"
daemon_pid=""
cleanup() {
  if [[ -n "${daemon_pid}" ]] && kill -0 "${daemon_pid}" 2>/dev/null; then
    kill "${daemon_pid}" 2>/dev/null || true
    wait "${daemon_pid}" 2>/dev/null || true
  fi
  rm -rf "${tmpdir}"
}
trap cleanup EXIT
index_path="${tmpdir}/orient.index"
fallback_bench="${tmpdir}/orient-fallback-bench.json"
indexed_bench="${tmpdir}/orient-indexed-bench.json"
shard_dir="${tmpdir}/orient-shards"
route_workspace="${tmpdir}/route-workspace"
route_shard_dir="${tmpdir}/route-shards"
churn_repo="${tmpdir}/churn-repo"
churn_shard_dir="${tmpdir}/churn-shards"
cold_daemon_addr="${ORIENT_PERF_GATES_COLD_DAEMON_ADDR:-127.0.0.1:8794}"
mixed_daemon_addr="${ORIENT_PERF_GATES_MIXED_DAEMON_ADDR:-127.0.0.1:8798}"

target/release/orient bench-search \
  --repo . \
  --runs 5 \
  --warmup 1 \
  --limit 10 \
  --fail-p95-ms 1000 \
  "indexed search symbol filters" \
  "read range tool manifest" \
  "file:Cargo.toml"

target/release/orient index --repo . --output "${index_path}"
target/release/orient bench-search \
  --repo . \
  --index "${index_path}" \
  --runs 5 \
  --warmup 1 \
  --limit 10 \
  --fail-p95-ms 500 \
  "indexed search symbol filters" \
  "read range tool manifest"

target/release/orient bench-search \
  --repo . \
  --runs 7 \
  --warmup 2 \
  --limit 10 \
  "indexed search symbol filters" \
  "read range tool manifest" \
  > "${fallback_bench}"
target/release/orient bench-search \
  --repo . \
  --index "${index_path}" \
  --runs 7 \
  --warmup 2 \
  --limit 10 \
  --baseline "${fallback_bench}" \
  --allow-baseline-mode-mismatch \
  --require-faster-than-baseline \
  --max-p95-regression 0 \
  "indexed search symbol filters" \
  "read range tool manifest" \
  > "${indexed_bench}"

target/release/orient ensure-shards \
  --repo . \
  --output-dir "${shard_dir}"
target/release/orient bench-shards \
  --index-dir "${shard_dir}" \
  --cold \
  --runs 5 \
  --warmup 1 \
  --limit 10 \
  --fail-p95-ms 100 \
  "globally_absent_orient_prefilter_probe_xyz"

target/release/orient bench-shards \
  --index-dir "${shard_dir}" \
  --cached \
  --runs 5 \
  --warmup 1 \
  --limit 10 \
  --fail-p95-ms 1000 \
  "indexed search symbol filters" \
  "file:Cargo.toml"

mkdir -p "${route_workspace}"
route_repos=()
for index in $(seq 0 95); do
  repo="${route_workspace}/route-repo-${index}"
  route_repos+=(--repo "${repo}")
  mkdir -p "${repo}/src" "${repo}/.git"
  cat > "${repo}/src/lib.rs" <<EOF
pub fn commonroutegate() -> usize { ${index} }
pub fn read() -> usize { ${index} }
pub fn range() -> usize { ${index} }
pub fn token() -> usize { ${index} }
// Noisy prose: route symbol token decoys should not satisfy symbol filters.
EOF
done
cat >> "${route_workspace}/route-repo-42/src/lib.rs" <<'EOF'
pub fn unique42needle() -> usize { 42 }
pub fn read_range() -> usize { 42 }
pub struct RouteSymbolManager;
EOF

target/release/orient ensure-shards \
  "${route_repos[@]}" \
  --output-dir "${route_shard_dir}"
target/release/orient search \
  --index-dir "${route_shard_dir}" \
  --query "kind:function unique42needle" \
  --limit 10 \
  | grep -q "route-repo-42/src/lib.rs"
target/release/orient bench-shards \
  --index-dir "${route_shard_dir}" \
  --cold \
  --runs 5 \
  --warmup 1 \
  --limit 10 \
  --fail-p95-ms 50 \
  "kind:function unique42needle"
target/release/orient search \
  --index-dir "${route_shard_dir}" \
  --query "read_range" \
  --limit 10 \
  | grep -q "route-repo-42/src/lib.rs"
target/release/orient bench-shards \
  --index-dir "${route_shard_dir}" \
  --cold \
  --runs 5 \
  --warmup 1 \
  --limit 10 \
  --fail-p95-ms 50 \
  "read_range"
target/release/orient search \
  --index-dir "${route_shard_dir}" \
  --query "symbol:RouteSymbolManager token" \
  --limit 10 \
  | grep -q "route-repo-42/src/lib.rs"
target/release/orient bench-shards \
  --index-dir "${route_shard_dir}" \
  --cached \
  --runs 5 \
  --warmup 1 \
  --limit 10 \
  --fail-p95-ms 50 \
  "symbol:RouteSymbolManager token"

cold_daemon_log="${tmpdir}/orient-daemon-cold.log"
target/release/orient serve-tcp \
  --addr "${cold_daemon_addr}" \
  --index-dir "${route_shard_dir}" \
  --max-cached-indexes 2 \
  >"${cold_daemon_log}" 2>&1 &
daemon_pid="$!"

cold_ready=0
for _ in $(seq 1 60); do
  if printf '%s\n' '{"id":"status","tool":"daemon_status","arguments":{}}' \
    | target/release/orient client-jsonl --addr "${cold_daemon_addr}" --require-version >/dev/null 2>&1; then
    cold_ready=1
    break
  fi
  if ! kill -0 "${daemon_pid}" 2>/dev/null; then
    echo "daemon exited before cold contention gate readiness" >&2
    cat "${cold_daemon_log}" >&2 || true
    exit 1
  fi
  sleep 1
done
if [[ "${cold_ready}" != "1" ]]; then
  echo "daemon did not become ready for cold contention gate at ${cold_daemon_addr}" >&2
  cat "${cold_daemon_log}" >&2 || true
  exit 1
fi

cold_cwds=()
for index in $(seq 0 7); do
  cold_cwds+=(--cwd "${route_workspace}/route-repo-${index}")
done
target/release/orient bench-daemon-contend \
  --addr "${cold_daemon_addr}" \
  "${cold_cwds[@]}" \
  --clients 8 \
  --runs 3 \
  --warmup 0 \
  --jitter-ms 0 \
  --limit 10 \
  --request-timeout-ms 30000 \
  --fail-p95-ms 250 \
  --fail-p99-ms 300 \
  --fail-first-wave-p95-ms 250 \
  --fail-fallback-rate 0 \
  --query "commonroutegate"

kill "${daemon_pid}" 2>/dev/null || true
wait "${daemon_pid}" 2>/dev/null || true
daemon_pid=""

mixed_daemon_log="${tmpdir}/orient-daemon-mixed.log"
target/release/orient serve-tcp \
  --addr "${mixed_daemon_addr}" \
  --index-dir "${route_shard_dir}" \
  --warm-repo "${route_workspace}/route-repo-0" \
  --warm-repo "${route_workspace}/route-repo-42" \
  --warm-query "commonroutegate" \
  --max-cached-indexes 2 \
  >"${mixed_daemon_log}" 2>&1 &
daemon_pid="$!"

mixed_ready=0
for _ in $(seq 1 60); do
  if printf '%s\n' '{"id":"status","tool":"daemon_status","arguments":{}}' \
    | target/release/orient client-jsonl --addr "${mixed_daemon_addr}" --require-version >/dev/null 2>&1; then
    mixed_ready=1
    break
  fi
  if ! kill -0 "${daemon_pid}" 2>/dev/null; then
    echo "daemon exited before mixed contention gate readiness" >&2
    cat "${mixed_daemon_log}" >&2 || true
    exit 1
  fi
  sleep 1
done
if [[ "${mixed_ready}" != "1" ]]; then
  echo "daemon did not become ready for mixed contention gate at ${mixed_daemon_addr}" >&2
  cat "${mixed_daemon_log}" >&2 || true
  exit 1
fi

mixed_cwds=()
for _ in $(seq 1 5); do
  mixed_cwds+=(--cwd "${route_workspace}/route-repo-0")
  mixed_cwds+=(--cwd "${route_workspace}/route-repo-42")
done
mixed_ranges=()
for _ in $(seq 1 8); do
  mixed_ranges+=(--range "src/lib.rs:1:4")
done
target/release/orient bench-daemon-contend \
  --addr "${mixed_daemon_addr}" \
  "${mixed_cwds[@]}" \
  --clients 10 \
  --runs 8 \
  --warmup 3 \
  --jitter-ms 10 \
  --limit 10 \
  --request-timeout-ms 30000 \
  --fail-p95-ms 150 \
  --fail-p99-ms 300 \
  --fail-fallback-rate 0 \
  --query "commonroutegate" \
  --query "commonroutegate" \
  "${mixed_ranges[@]}"

kill "${daemon_pid}" 2>/dev/null || true
wait "${daemon_pid}" 2>/dev/null || true
daemon_pid=""

mkdir -p "${churn_repo}/src" "${churn_repo}/.git"
cat > "${churn_repo}/Cargo.toml" <<'EOF'
[package]
name = "orient-churn-gate"
version = "0.1.0"
edition = "2024"
EOF
cat > "${churn_repo}/src/lib.rs" <<'EOF'
pub fn baseline_search_token() -> &'static str { "baseline" }
EOF

target/release/orient ensure-shards \
  --repo "${churn_repo}" \
  --output-dir "${churn_shard_dir}"

daemon_addr="${ORIENT_PERF_GATES_DAEMON_ADDR:-127.0.0.1:8795}"
daemon_log="${tmpdir}/orient-daemon-churn.log"
target/release/orient serve-tcp \
  --addr "${daemon_addr}" \
  --index-dir "${churn_shard_dir}" \
  --warm-repo "${churn_repo}" \
  --max-cached-indexes 2 \
  >"${daemon_log}" 2>&1 &
daemon_pid="$!"

daemon_ready=0
for _ in $(seq 1 60); do
  if printf '%s\n' '{"id":"status","tool":"daemon_status","arguments":{}}' \
    | target/release/orient client-jsonl --addr "${daemon_addr}" --require-version >/dev/null 2>&1; then
    daemon_ready=1
    break
  fi
  if ! kill -0 "${daemon_pid}" 2>/dev/null; then
    echo "daemon exited before churn gate readiness" >&2
    cat "${daemon_log}" >&2 || true
    exit 1
  fi
  sleep 1
done
if [[ "${daemon_ready}" != "1" ]]; then
  echo "daemon did not become ready for churn gate at ${daemon_addr}" >&2
  cat "${daemon_log}" >&2 || true
  exit 1
fi

target/release/orient bench-daemon-churn \
  --addr "${daemon_addr}" \
  --cwd "${churn_repo}" \
  --concurrency 4 \
  --runs 5 \
  --warmup 2 \
  --baseline-runs 2 \
  --churn-files 2 \
  --limit 10 \
  --request-timeout-ms 30000 \
  --fail-p95-ms 1000 \
  --fail-p99-ms 1000 \
  --fail-fallback-rate 0 \
  --fail-refresh-overhead-ms 250 \
  --query "orient_churn_token"
