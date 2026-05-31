# Benchmarking

Orient has four benchmark layers:

- `tools/ci/orient_perf_gates.sh` is the small CI gate. It keeps release builds,
  unit-level search behavior, JSON-lines smoke coverage, and latency regressions
  honest on the current repo.
- `tools/ci/orient_agent_query_perf.sh` is the local agent-workload benchmark.
  It discovers a local workspace, builds shards with worktree-family limiting,
  and runs a mixed query set that looks like what coding agents ask for.
- `orient bench-daemon` is the shared-daemon concurrency benchmark. It sends
  simultaneous JSON-lines `search_auto` requests to one daemon so a local
  multi-agent setup can check queueing and tail latency.
- `orient bench-daemon-read` checks the follow-up path after search by sending
  concurrent bounded `read_range` requests to the daemon.
- `orient bench-daemon-mix` checks the real agent loop by mixing concurrent
  `search_auto` and `read_range` requests in the same wave.
- `orient bench-daemon-churn` checks the same mixed path while editing small
  marker files between waves, so stale-refresh and fallback-cliff behavior are
  visible under load.
- `orient bench-daemon-contend` runs many independent client loops with optional
  per-client `cwd` scopes, jitter, mixed search/read operations, and wall-clock
  throughput reporting. This is the closest built-in shape to several local
  coding agents sharing one daemon.
- `tools/ci/orient_daemon_cwd_perf.sh` is the local shared-daemon benchmark. It
  warms shards, scopes requests through a checkout `cwd`, and gates repeated
  concurrent `search_auto` latency for the path coding agents normally use.
- `tools/ci/orient_daemon_contention_perf.sh` is the multi-agent shared-daemon
  benchmark. It warms and pins the active repos, then runs several client loops
  through `bench-daemon-contend`.

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

Run the local shared-daemon benchmark with:

```bash
ORIENT_DAEMON_CWD_ROOT=/path/to/projects \
ORIENT_DAEMON_CWD=/path/to/projects/current-checkout \
ORIENT_DAEMON_CWD_OUTPUT_DIR=/tmp/orient-daemon-cwd-shards \
tools/ci/orient_daemon_cwd_perf.sh
```

Set `ORIENT_DAEMON_CWD_REBUILD_SHARDS=1` to rebuild shards, or leave it unset
to reuse an existing shard directory when possible. The default p95 gate is
300ms and can be changed with `ORIENT_DAEMON_CWD_P95_MS`.

Run the multi-agent contention benchmark with:

```bash
ORIENT_DAEMON_CONTEND_ROOT=/path/to/projects \
ORIENT_DAEMON_CONTEND_OUTPUT_DIR=/tmp/orient-shards \
ORIENT_DAEMON_CONTEND_CWDS=/path/to/repo-a:/path/to/repo-b \
ORIENT_DAEMON_CONTEND_MODE=both \
tools/ci/orient_daemon_contention_perf.sh
```

Use `ORIENT_DAEMON_CONTEND_MODE=cold` to measure first-touch behavior, `warm`
to measure pinned active repos, or `both` to run the pair. Query and range files
can be supplied with `ORIENT_DAEMON_CONTEND_QUERY_FILE` and
`ORIENT_DAEMON_CONTEND_RANGE_FILE`.

## Shared Daemon Matrix

For agent-heavy local development, benchmark the shared daemon in two modes:

1. cold first touch, where the daemon knows the shard directory but has not
   loaded hot repos or warmed common queries
2. warm steady state, where the daemon preloads the active repos and precomputes
   the queries agents tend to issue first

Start a cold daemon with:

```bash
orient serve-tcp \
  --addr 127.0.0.1:8796 \
  --index-dir /tmp/orient-shards \
  --max-cached-indexes 64
```

Then measure several client loops against the active checkouts:

```bash
orient bench-daemon-contend \
  --addr 127.0.0.1:8796 \
  --cwd /path/to/repo-a \
  --cwd /path/to/repo-b \
  --clients 10 \
  --runs 20 \
  --warmup 0 \
  --jitter-ms 25 \
  --request-timeout-ms 30000 \
  --query "file:package.json" \
  --query "kind:function search" \
  --query "path:src auth token" \
  --range package.json:1:40
```

Restart the daemon with warm repos and common warm queries:

```bash
orient serve-tcp \
  --addr 127.0.0.1:8796 \
  --index-dir /tmp/orient-shards \
  --warm-repo /path/to/repo-a \
  --warm-repo /path/to/repo-b \
  --warm-query "file:package.json" \
  --warm-query "kind:function search" \
  --warm-query "path:src auth token" \
  --max-cached-indexes 64
```

Run the same `bench-daemon-contend` command again with `--warmup 5`. The cold
run should show first-touch cost through `first_wave_p95_ms` and
`first_wave_max_ms`; the warm run should drive `fallback_rate` to zero and keep
steady-state p95 in low milliseconds for repo-scoped agent queries. If warm
latency is good but cold first wave is high, prioritize repo/query prewarming,
hot-repo pinning, and first-touch coalescing before broad fallback tuning.

For a running shared daemon, check concurrent local-agent search latency with:

```bash
orient bench-daemon \
  --addr 127.0.0.1:8796 \
  --cwd /path/to/current/repo \
  --concurrency 10 \
  --runs 10 \
  --warmup 2 \
  --request-timeout-ms 30000 \
  --query "symbol:SessionManager token" \
  --query "file:Cargo.toml"
```

`bench-daemon` reports one sample per request, so `sample_count` is
`runs * concurrency * query_count`. Use `--cwd` to mirror how agent wrappers
scope shared shard daemons to the current checkout. The request timeout bounds
each daemon round trip so a stalled daemon fails the benchmark instead of
hanging the caller. For warmed multi-shard daemons, compare the startup
`cached_indexes` and `max_cached_indexes` fields; a cache smaller than the shard
count can turn broad fanout queries into cache churn. Also check
`max_concurrent_shard_workers`; this is the daemon-wide fanout budget shared by
concurrent requests and defaults to `max_shard_workers`, the per-query cap.

Check the bounded context-read path with:

```bash
orient bench-daemon-read \
  --addr 127.0.0.1:8796 \
  --cwd /path/to/current/repo \
  --concurrency 10 \
  --runs 10 \
  --warmup 2 \
  --request-timeout-ms 30000 \
  --range src/main.rs:1:40 \
  --range README.md:1:40
```

For `bench-daemon-read`, each reported query is a range label and
`result_count` is the line count returned by `read_range`.

Check the mixed search/read path with:

```bash
orient bench-daemon-mix \
  --addr 127.0.0.1:8796 \
  --cwd /path/to/current/repo \
  --concurrency 10 \
  --runs 10 \
  --warmup 2 \
  --request-timeout-ms 30000 \
  --query "symbol:SessionManager token" \
  --query "file:Cargo.toml" \
  --range src/main.rs:1:40 \
  --range README.md:1:40
```

For `bench-daemon-mix`, labels are prefixed with `search:` or `read:` so the
same report shows both sides of the agent search-to-read handoff.

Check live-edit behavior with:

```bash
orient bench-daemon-churn \
  --addr 127.0.0.1:8796 \
  --cwd /path/to/current/repo \
  --concurrency 10 \
  --runs 10 \
  --warmup 2 \
  --baseline-runs 3 \
  --request-timeout-ms 30000 \
  --query orient_churn_token \
  --fail-fallback-rate 0.01
```

`bench-daemon-churn` writes `orient_churn_token` marker files under
`.orient-churn-bench` inside `--cwd`, runs `search_auto` with
`refresh_if_stale:true` and `retry_if_empty:true`, and removes the marker files
unless `--keep-churn-files` is set. Reports include `fallback_count`,
`stale_count`, `primary_retry_count`, `refresh_request_count`, `fallback_rate`,
`churn_writes`, `baseline_max_p95_ms`, and `refresh_overhead_max_p95_ms`.
`fallback_rate` is measured over search samples. The baseline waves run before
the edits so refresh cost is visible instead of being hidden inside one p95.

Check shared-daemon contention with:

```bash
orient bench-daemon-contend \
  --addr 127.0.0.1:8796 \
  --cwd /path/to/repo-a \
  --cwd /path/to/repo-b \
  --clients 10 \
  --runs 40 \
  --warmup 5 \
  --jitter-ms 50 \
  --request-timeout-ms 30000 \
  --query "symbol:SessionManager token" \
  --query "file:Cargo.toml" \
  --range src/main.rs:1:40
```

`bench-daemon-contend` assigns clients round-robin across the supplied `--cwd`
values, chooses search/read operations round-robin per client, and sleeps a
deterministic jitter between operations. It reports `sample_count` as
`clients * runs`, keeps per-operation p50/p95/p99/max samples, and adds
`wall_ms`, `ops_per_sec`, `first_wave_p95_ms`, and `first_wave_max_ms` to the
summary. Use it when several local agent processes share one daemon and you care
about contention rather than a single synchronized wave.

For cold-start behavior, start a fresh daemon and run the same command with
`--warmup 0`. The first-wave fields then show the initial concurrent touch cost.
Run it again with the normal warmup value to compare cold first touch against
steady shared-daemon behavior.

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
