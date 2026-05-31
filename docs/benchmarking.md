# Benchmarking

Orient has three benchmark layers:

- `tools/ci/orient_perf_gates.sh` is the small CI gate. It keeps release builds,
  unit-level search behavior, JSON-lines smoke coverage, and latency regressions
  honest on the current repo.
- `tools/ci/orient_agent_query_perf.sh` is the local agent-workload benchmark.
  It discovers a local workspace, builds shards with worktree-family limiting,
  and runs a mixed query set that looks like what coding agents ask for.
- `orient bench-daemon` is the shared-daemon concurrency benchmark. It sends
  simultaneous JSON-lines `search_auto` requests to one daemon so a local
  multi-agent setup can check queueing and tail latency.

Run the local agent benchmark with:

```bash
ORIENT_AGENT_ROOT=/path/to/projects \
ORIENT_AGENT_OUTPUT_DIR=/tmp/orient-agent-shards \
ORIENT_AGENT_FAMILY_LIMIT=1 \
tools/ci/orient_agent_query_perf.sh | tee /tmp/orient-agent-bench.jsonl
```

Use `ORIENT_AGENT_QUERY_FILE=/path/to/queries.txt` to replace the default query
set. Blank lines and `#` comments are ignored. Use
`ORIENT_AGENT_REBUILD_SHARDS=0` to reuse an existing shard directory, and set
`ORIENT_AGENT_FALLBACK=0` when only cached shard latency matters.

For a running shared daemon, check concurrent local-agent search latency with:

```bash
orient bench-daemon \
  --addr 127.0.0.1:8796 \
  --cwd /path/to/current/repo \
  --concurrency 10 \
  --runs 10 \
  --warmup 2 \
  --query "symbol:SessionManager token" \
  --query "file:Cargo.toml"
```

`bench-daemon` reports one sample per request, so `sample_count` is
`runs * concurrency * query_count`. Use `--cwd` to mirror how agent wrappers
scope shared shard daemons to the current checkout.

The default query set intentionally mixes:

- broad orientation queries, such as `search query plan`
- bounded file lookups, such as `file:Cargo.toml`
- broad symbol filters, such as `kind:function handler`
- structural scopes, such as `path:src auth token`
- language and manifest-oriented queries

Interpret results in two buckets. Repo-scoped, file-scoped, and language-scoped
queries should stay in low double-digit milliseconds on warm shards. Broad
unscoped queries over very large multi-checkout workspaces are expected to expose
routing and fanout limits; those numbers are planning inputs, not CI gates.
For shard benchmarks, inspect each query's `shard_route` field. `selected_shards`
near `total_shards` means the query is paying broad fanout cost before ranking.

Current local baselines show the useful shape:

- On a medium workspace, cached shard p95 is single-digit to low double-digit
  milliseconds for scoped queries, while broad symbol-kind queries can climb into
  tens of milliseconds.
- On a large multi-checkout workspace, repo-scoped queries remain single-digit
  milliseconds, but broad unscoped all-shard queries can reach second-scale p95.

That points the next performance work at global shard routing for broad queries,
symbol-kind/path-aware shard prefilters, and daemon queueing under concurrent
local agents.
Do not commit local benchmark JSONL files from private workspaces.
