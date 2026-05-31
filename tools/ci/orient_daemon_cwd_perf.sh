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

if [[ -n "${ORIENT_DAEMON_CWD_ROOT:-}" ]]; then
  root="${ORIENT_DAEMON_CWD_ROOT}"
elif [[ -d "${user_home}/Documents/Projects" ]]; then
  root="${user_home}/Documents/Projects"
else
  root="${user_home}/code"
fi

output_dir="${ORIENT_DAEMON_CWD_OUTPUT_DIR:-/tmp/orient-daemon-cwd-shards}"
addr="${ORIENT_DAEMON_CWD_ADDR:-127.0.0.1:8797}"
family_limit="${ORIENT_DAEMON_CWD_FAMILY_LIMIT:-1}"
concurrency="${ORIENT_DAEMON_CWD_CONCURRENCY:-10}"
runs="${ORIENT_DAEMON_CWD_RUNS:-5}"
warmup="${ORIENT_DAEMON_CWD_WARMUP:-2}"
limit="${ORIENT_DAEMON_CWD_LIMIT:-10}"
request_timeout_ms="${ORIENT_DAEMON_CWD_REQUEST_TIMEOUT_MS:-30000}"
p95_ms="${ORIENT_DAEMON_CWD_P95_MS:-300}"
max_depth="${ORIENT_DAEMON_CWD_MAX_DEPTH:-4}"
discover_limit="${ORIENT_DAEMON_CWD_DISCOVER_LIMIT:-500}"

if [[ ! -d "${root}" ]]; then
  if [[ "${ORIENT_DAEMON_CWD_REQUIRE_ROOT:-0}" == "1" ]]; then
    echo "daemon cwd perf root does not exist: ${root}" >&2
    exit 1
  fi
  echo "skipping daemon cwd perf; root does not exist: ${root}" >&2
  exit 0
fi

if [[ -n "${ORIENT_DAEMON_CWD:-}" ]]; then
  cwd="${ORIENT_DAEMON_CWD}"
elif [[ -d "${root}/.git" || -f "${root}/.git" ]]; then
  cwd="${root}"
else
  git_dir="$(
    find "${root}" \
      -maxdepth "${max_depth}" \
      \( -type d -o -type f \) \
      -name .git \
      -print \
      -quit
  )"
  if [[ -z "${git_dir}" ]]; then
    echo "skipping daemon cwd perf; no git checkout found under ${root}" >&2
    exit 0
  fi
  cwd="$(dirname "${git_dir}")"
fi

if [[ ! -d "${cwd}" ]]; then
  echo "daemon cwd perf cwd does not exist: ${cwd}" >&2
  exit 1
fi

queries=()
if [[ -n "${ORIENT_DAEMON_CWD_QUERY_FILE:-}" ]]; then
  while IFS= read -r query || [[ -n "${query}" ]]; do
    [[ -z "${query}" || "${query}" == \#* ]] && continue
    queries+=("${query}")
  done < "${ORIENT_DAEMON_CWD_QUERY_FILE}"
else
  queries=(
    "symbol:ToolRuntime search"
    "file:Cargo.toml"
    "search query plan"
    "path:src auth token"
  )
fi

query_args=()
for query in "${queries[@]}"; do
  query_args+=(--query "${query}")
done

cargo build --release

if [[ "${ORIENT_DAEMON_CWD_REBUILD_SHARDS:-0}" == "1" || ! -f "${output_dir}/manifest.json" ]]; then
  rm -rf "${output_dir}"
  echo "daemon cwd shard build: root=${root} output_dir=${output_dir} family_limit=${family_limit}" >&2
  target/release/orient ensure-shards \
    --discover-root "${root}" \
    --output-dir "${output_dir}" \
    --family-limit "${family_limit}" \
    --max-depth "${max_depth}" \
    --discover-limit "${discover_limit}"
fi

daemon_log="$(mktemp "${TMPDIR:-/tmp}/orient-daemon-cwd.XXXXXX.log")"
daemon_pid=""
cleanup() {
  if [[ -n "${daemon_pid}" ]] && kill -0 "${daemon_pid}" 2>/dev/null; then
    kill "${daemon_pid}" 2>/dev/null || true
    wait "${daemon_pid}" 2>/dev/null || true
  fi
  rm -f "${daemon_log}"
}
trap cleanup EXIT

echo "daemon cwd serve: addr=${addr} index_dir=${output_dir} cwd=${cwd}" >&2
target/release/orient serve-tcp \
  --addr "${addr}" \
  --index-dir "${output_dir}" \
  --warm-index-dir "${output_dir}" \
  --max-cached-indexes "${ORIENT_DAEMON_CWD_MAX_CACHED_INDEXES:-512}" \
  >"${daemon_log}" 2>&1 &
daemon_pid="$!"

ready=0
for _ in $(seq 1 60); do
  if printf '%s\n' '{"id":"status","tool":"daemon_status","arguments":{}}' \
    | target/release/orient client-jsonl --addr "${addr}" --require-version >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "${daemon_pid}" 2>/dev/null; then
    echo "daemon exited before readiness" >&2
    cat "${daemon_log}" >&2 || true
    exit 1
  fi
  sleep 1
done

if [[ "${ready}" != "1" ]]; then
  echo "daemon did not become ready at ${addr}" >&2
  cat "${daemon_log}" >&2 || true
  exit 1
fi

echo "daemon cwd bench: cwd=${cwd} concurrency=${concurrency} p95<=${p95_ms}ms" >&2
target/release/orient bench-daemon \
  --addr "${addr}" \
  --cwd "${cwd}" \
  --concurrency "${concurrency}" \
  --runs "${runs}" \
  --warmup "${warmup}" \
  --limit "${limit}" \
  --request-timeout-ms "${request_timeout_ms}" \
  --fail-p95-ms "${p95_ms}" \
  "${query_args[@]}"
