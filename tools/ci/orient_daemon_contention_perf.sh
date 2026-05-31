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

root="${ORIENT_DAEMON_CONTEND_ROOT:-${user_home}/Documents/Projects}"
output_dir="${ORIENT_DAEMON_CONTEND_OUTPUT_DIR:-/tmp/orient-daemon-contend-shards}"
addr="${ORIENT_DAEMON_CONTEND_ADDR:-127.0.0.1:8797}"
family_limit="${ORIENT_DAEMON_CONTEND_FAMILY_LIMIT:-2}"
clients="${ORIENT_DAEMON_CONTEND_CLIENTS:-10}"
runs="${ORIENT_DAEMON_CONTEND_RUNS:-20}"
warmup="${ORIENT_DAEMON_CONTEND_WARMUP:-5}"
limit="${ORIENT_DAEMON_CONTEND_LIMIT:-10}"
jitter_ms="${ORIENT_DAEMON_CONTEND_JITTER_MS:-25}"
request_timeout_ms="${ORIENT_DAEMON_CONTEND_REQUEST_TIMEOUT_MS:-30000}"
max_cached_indexes="${ORIENT_DAEMON_CONTEND_MAX_CACHED_INDEXES:-2}"
max_depth="${ORIENT_DAEMON_CONTEND_MAX_DEPTH:-4}"
discover_limit="${ORIENT_DAEMON_CONTEND_DISCOVER_LIMIT:-500}"
mode="${ORIENT_DAEMON_CONTEND_MODE:-warm}"
p95_threshold_ms="${ORIENT_DAEMON_CONTEND_FAIL_P95_MS:-}"
p99_threshold_ms="${ORIENT_DAEMON_CONTEND_FAIL_P99_MS:-}"
fallback_rate_threshold="${ORIENT_DAEMON_CONTEND_FAIL_FALLBACK_RATE:-}"

if [[ ! -d "${root}" ]]; then
  if [[ "${ORIENT_DAEMON_CONTEND_REQUIRE_ROOT:-0}" == "1" ]]; then
    echo "daemon contention root does not exist: ${root}" >&2
    exit 1
  fi
  echo "skipping daemon contention perf; root does not exist: ${root}" >&2
  exit 0
fi

cwds=()
if [[ -n "${ORIENT_DAEMON_CONTEND_CWDS:-}" ]]; then
  IFS=: read -r -a cwds <<<"${ORIENT_DAEMON_CONTEND_CWDS}"
else
  if [[ -n "${ORIENT_DAEMON_CONTEND_CWD_A:-}" ]]; then
    cwds+=("${ORIENT_DAEMON_CONTEND_CWD_A}")
  fi
  if [[ -n "${ORIENT_DAEMON_CONTEND_CWD_B:-}" ]]; then
    cwds+=("${ORIENT_DAEMON_CONTEND_CWD_B}")
  fi
fi

if [[ "${#cwds[@]}" -eq 0 ]]; then
  while IFS= read -r git_dir && [[ "${#cwds[@]}" -lt 2 ]]; do
    cwds+=("$(dirname "${git_dir}")")
  done < <(
    find "${root}" \
      -maxdepth "${max_depth}" \
      \( -type d -o -type f \) \
      -name .git \
      -print
  )
fi

if [[ "${#cwds[@]}" -eq 0 ]]; then
  echo "skipping daemon contention perf; no git checkout found under ${root}" >&2
  exit 0
fi

for cwd in "${cwds[@]}"; do
  if [[ ! -d "${cwd}" ]]; then
    echo "daemon contention cwd does not exist: ${cwd}" >&2
    exit 1
  fi
done

queries=()
if [[ -n "${ORIENT_DAEMON_CONTEND_QUERY_FILE:-}" ]]; then
  while IFS= read -r query || [[ -n "${query}" ]]; do
    [[ -z "${query}" || "${query}" == \#* ]] && continue
    queries+=("${query}")
  done < "${ORIENT_DAEMON_CONTEND_QUERY_FILE}"
else
  queries=(
    "file:README.md"
    "kind:function handler"
    "path:src auth token"
  )
fi

ranges=()
if [[ -n "${ORIENT_DAEMON_CONTEND_RANGE_FILE:-}" ]]; then
  while IFS= read -r range || [[ -n "${range}" ]]; do
    [[ -z "${range}" || "${range}" == \#* ]] && continue
    ranges+=("${range}")
  done < "${ORIENT_DAEMON_CONTEND_RANGE_FILE}"
else
  ranges=("README.md:1:40")
fi

query_args=()
warm_query_args=()
for query in "${queries[@]}"; do
  query_args+=(--query "${query}")
  warm_query_args+=(--warm-query "${query}")
done

range_args=()
for range in "${ranges[@]}"; do
  range_args+=(--range "${range}")
done

gate_args=()
if [[ -n "${p95_threshold_ms}" ]]; then
  gate_args+=(--fail-p95-ms "${p95_threshold_ms}")
fi
if [[ -n "${p99_threshold_ms}" ]]; then
  gate_args+=(--fail-p99-ms "${p99_threshold_ms}")
fi
if [[ -n "${fallback_rate_threshold}" ]]; then
  gate_args+=(--fail-fallback-rate "${fallback_rate_threshold}")
fi

cwd_args=()
warm_repo_args=()
for cwd in "${cwds[@]}"; do
  cwd_args+=(--cwd "${cwd}")
  warm_repo_args+=(--warm-repo "${cwd}")
done

cargo build --release

if [[ "${ORIENT_DAEMON_CONTEND_REBUILD_SHARDS:-0}" == "1" || ! -f "${output_dir}/manifest.json" ]]; then
  rm -rf "${output_dir}"
  echo "daemon contention shard build: root=${root} output_dir=${output_dir} family_limit=${family_limit}" >&2
  target/release/orient ensure-shards \
    --discover-root "${root}" \
    --output-dir "${output_dir}" \
    --family-limit "${family_limit}" \
    --max-depth "${max_depth}" \
    --discover-limit "${discover_limit}"
fi

run_case() {
  local label="$1"
  shift

  local daemon_log
  daemon_log="$(mktemp "${TMPDIR:-/tmp}/orient-daemon-contend.XXXXXX")"
  local daemon_pid=""
  cleanup_case() {
    if [[ -n "${daemon_pid}" ]] && kill -0 "${daemon_pid}" 2>/dev/null; then
      kill "${daemon_pid}" 2>/dev/null || true
      wait "${daemon_pid}" 2>/dev/null || true
    fi
    rm -f "${daemon_log}"
  }
  trap cleanup_case RETURN

  echo "daemon contention serve (${label}): addr=${addr} index_dir=${output_dir} cwds=${cwds[*]}" >&2
  target/release/orient serve-tcp \
    --addr "${addr}" \
    --index-dir "${output_dir}" \
    --max-cached-indexes "${max_cached_indexes}" \
    "$@" \
    >"${daemon_log}" 2>&1 &
  daemon_pid="$!"

  local ready=0
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

  echo "daemon contention bench (${label}): clients=${clients} runs=${runs} warmup=${warmup}" >&2
  target/release/orient bench-daemon-contend \
    --addr "${addr}" \
    "${cwd_args[@]}" \
    --clients "${clients}" \
    --runs "${runs}" \
    --warmup "${warmup}" \
    --jitter-ms "${jitter_ms}" \
    --limit "${limit}" \
    --request-timeout-ms "${request_timeout_ms}" \
    "${gate_args[@]}" \
    "${query_args[@]}" \
    "${range_args[@]}"
}

case "${mode}" in
  cold)
    run_case "cold"
    ;;
  warm)
    run_case "warm" "${warm_repo_args[@]}" "${warm_query_args[@]}"
    ;;
  both)
    run_case "cold"
    run_case "warm" "${warm_repo_args[@]}" "${warm_query_args[@]}"
    ;;
  *)
    echo "unknown ORIENT_DAEMON_CONTEND_MODE: ${mode}" >&2
    exit 1
    ;;
esac
