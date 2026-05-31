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

if [[ -n "${ORIENT_AGENT_ROOT:-}" ]]; then
  root="${ORIENT_AGENT_ROOT}"
elif [[ -d "${user_home}/Documents/Projects" ]]; then
  root="${user_home}/Documents/Projects"
else
  root="${user_home}/code"
fi

output_dir="${ORIENT_AGENT_OUTPUT_DIR:-/tmp/orient-agent-shards}"
family_limit="${ORIENT_AGENT_FAMILY_LIMIT:-1}"
fallback="${ORIENT_AGENT_FALLBACK:-1}"
shards="${ORIENT_AGENT_SHARDS:-1}"
runs="${ORIENT_AGENT_RUNS:-7}"
warmup="${ORIENT_AGENT_WARMUP:-2}"
shard_runs="${ORIENT_AGENT_SHARD_RUNS:-${runs}}"
shard_warmup="${ORIENT_AGENT_SHARD_WARMUP:-${warmup}}"
limit="${ORIENT_AGENT_LIMIT:-10}"

if [[ ! -d "${root}" ]]; then
  echo "agent query perf root does not exist: ${root}" >&2
  exit 1
fi

queries=()
if [[ -n "${ORIENT_AGENT_QUERY_FILE:-}" ]]; then
  while IFS= read -r query || [[ -n "${query}" ]]; do
    [[ -z "${query}" || "${query}" == \#* ]] && continue
    queries+=("${query}")
  done < "${ORIENT_AGENT_QUERY_FILE}"
else
  queries=(
    "search query plan"
    "read range tool"
    "file:Cargo.toml"
    "kind:function handler"
    "kind:function search"
    "path:src auth token"
    "lang:go grpc status"
    "lang:typescript useEffect"
    "package json script"
    "docker compose service"
  )
fi

query_args=()
for query in "${queries[@]}"; do
  query_args+=(--query "${query}")
done

cargo build --release

if [[ "${fallback}" == "1" ]]; then
  fallback_threshold=()
  if [[ -n "${ORIENT_AGENT_FALLBACK_P95_MS:-}" ]]; then
    fallback_threshold+=(--fail-p95-ms "${ORIENT_AGENT_FALLBACK_P95_MS}")
  fi
  if [[ -n "${ORIENT_AGENT_FALLBACK_P99_MS:-}" ]]; then
    fallback_threshold+=(--fail-p99-ms "${ORIENT_AGENT_FALLBACK_P99_MS}")
  fi
  echo "agent fallback bench: root=${root}" >&2
  target/release/orient bench-search \
    --repo "${root}" \
    --mode fallback \
    --runs "${runs}" \
    --warmup "${warmup}" \
    --limit "${limit}" \
    "${fallback_threshold[@]}" \
    "${query_args[@]}"
else
  echo "skipping agent fallback bench; ORIENT_AGENT_FALLBACK=${fallback}" >&2
fi

if [[ "${shards}" == "1" ]]; then
  if [[ "${ORIENT_AGENT_REBUILD_SHARDS:-1}" == "1" || ! -f "${output_dir}/manifest.json" ]]; then
    rm -rf "${output_dir}"
    echo "agent shard build: root=${root} output_dir=${output_dir} family_limit=${family_limit}" >&2
    build_started_s="$(date +%s)"
    target/release/orient ensure-shards \
      --discover-root "${root}" \
      --output-dir "${output_dir}" \
      --family-limit "${family_limit}"
    build_finished_s="$(date +%s)"
    printf '{"mode":"agent_shard_build","build_seconds":%s,"output_dir":"%s"}\n' \
      "$((build_finished_s - build_started_s))" \
      "${output_dir//\"/\\\"}"
  fi

  echo "agent shard status: output_dir=${output_dir}" >&2
  target/release/orient shard-status --index-dir "${output_dir}" --summary

  shard_threshold=()
  if [[ -n "${ORIENT_AGENT_SHARD_P95_MS:-}" ]]; then
    shard_threshold+=(--fail-p95-ms "${ORIENT_AGENT_SHARD_P95_MS}")
  fi
  if [[ -n "${ORIENT_AGENT_SHARD_P99_MS:-}" ]]; then
    shard_threshold+=(--fail-p99-ms "${ORIENT_AGENT_SHARD_P99_MS}")
  fi

  echo "agent cached shard bench: output_dir=${output_dir}" >&2
  target/release/orient bench-shards \
    --index-dir "${output_dir}" \
    --cached \
    --runs "${shard_runs}" \
    --warmup "${shard_warmup}" \
    --limit "${limit}" \
    "${shard_threshold[@]}" \
    "${query_args[@]}"
else
  echo "skipping agent shard bench; ORIENT_AGENT_SHARDS=${shards}" >&2
fi
