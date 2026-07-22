# Orient Search

Fast local code search for coding agents.

Orient gives local agents repo maps, indexed search, query plans, and bounded
file reads so they stop repeating expensive filesystem scans. It stores local
code-search artifacts only and has no telemetry.

## Start A Shared Daemon

```bash
cargo install --git https://github.com/evalops/orient-search
orient --version

orient agent-bootstrap \
  --repo /path/to/current/repo \
  --output-dir /path/to/local/cache/orient-shards
```

Or run the shared daemon setup manually:

```bash
export ORIENT_WORKSPACES=/path/to/workspaces
export ORIENT_SHARDS=/path/to/local/cache/orient-shards

orient ensure-shards \
  --discover-root "$ORIENT_WORKSPACES" \
  --output-dir "$ORIENT_SHARDS" \
  --family-limit 2

orient serve-tcp \
  --addr 127.0.0.1:8796 \
  --index-dir "$ORIENT_SHARDS" \
  --warm-repo /path/to/current/repo \
  --warm-query "file:README.md"
```

`--index-dir` registers a shard manifest and loads repo indexes lazily. Use
`--warm-repo` for the one or two active checkouts agents are editing, and
`--max-cached-indexes N` when many repos share the daemon. Use
`--warm-index-dir "$ORIENT_SHARDS"` only when you intentionally want to load all
shards at startup.

Check the daemon and generate the agent-facing setup text:

```bash
orient doctor --index-dir "$ORIENT_SHARDS"
orient daemon-status
orient agent-instructions --profile generic --index-dir "$ORIENT_SHARDS"
```

Unix sockets are supported with `orient serve-unix --socket "$ORIENT_SOCKET"`.

## Search

```bash
orient search-auto --retry-if-empty --summary "symbol:SessionManager token"
orient search-auto --no-daemon "symbol:SessionManager token"
orient search --repo . "issue token"
orient search --index-dir "$ORIENT_SHARDS" "repo:service issue token"
orient read-range --repo . src/lib.rs:40:80
```

With no explicit target, `search-auto` tries the shared daemon at
`127.0.0.1:8796`, scopes daemon requests to the current checkout when possible,
then falls back to live local search. Set `ORIENT_ADDR`, `ORIENT_SOCKET`, or
`--no-daemon` to choose a different path.

Useful filters include `repo:`, `path:`/`dir:`, `file:`, `lang:`, `ext:`,
`symbol:`, `kind:`, `test:`, `generated:`, `code:`, `content:`, quoted phrases,
negative filters such as `-path:vendor`, and `mode:any` for broad orientation.
Pasted file locations, stack frames, test selectors, package scripts, Makefile
targets, Justfile targets, and Bazel labels resolve to anchored searches.

## Agent Protocol

Orient exposes JSON-lines, TCP, Unix socket, and MCP-shaped surfaces. Search
results include ready-to-run read, related-file, related-symbol, repo-map, and
query-plan follow-ups. Agents should run those returned requests directly
instead of translating them back into shell search/read commands.

```jsonl
{"id":"tools","tool":"tool_manifest","arguments":{}}
{"id":"search","tool":"search_auto","arguments":{"query":"repo:service symbol:SessionManager token","limit":10,"summary":true}}
{"id":"read","tool":"open_ranges","arguments":{"ranges":["service/src/auth.rs:40:80"]}}
```

Compact fields are the default place to look first:

- `query_plan_summary`, `summary`, and `next_action` explain what to do next.
- `read_request` and `next_read_batch_request` open bounded context.
- `refresh_request` refreshes stale scoped shards without rebuilding everything.
- `advice:true` or `--advice` returns short query-plan retry guidance.

See [Agent protocol](docs/agent-protocol.md) for the full tool surface.

## Footprint

Indexes contain source snapshots, line offsets, postings, symbols, and search
metadata so snippets and bounded reads stay fast from a shared daemon. Keep them
in a local cache and out of source control.

```bash
orient shard-status --index-dir "$ORIENT_SHARDS" --summary
```

## Warmth Plans

Orient can turn task intent into a deterministic, revision-fenced working set
for Orb or another cache manager. The plan includes the validated files needed
to reopen a shard and an ordered list of repository paths worth prefetching.

```bash
orient warmth-plan \
  --repo /path/to/current/repo \
  --index-dir "$ORIENT_SHARDS" \
  --query "fix session token refresh" \
  --max-paths 64 \
  --max-bytes 16777216 \
  --required-revision "$(git -C /path/to/current/repo rev-parse HEAD)"
```

Use `--heat observations.json` to add bounded historical path counts. Direct
search hits, related files, repo-map entrypoints/manifests/tests, and heat are
deduplicated before budget admission. Orient never uploads or archives these
files; it emits JSON for a trust-aware transport such as Orb to verify and use.
The equivalent JSON-lines tool is `warmth_plan`.
Reusable shard export requires a clean checkout and a single-repository shard
directory. Stale indexes, dirty or untracked files, and shared multi-repository
manifests fail closed instead of entering a revision-fenced capsule.
Every indexed source snapshot is also compared byte-for-byte with its blob in
the exact Git tree, so spoofed timestamps cannot relabel stale shard content.

## Benchmarks

For local performance work, start with the 10-client shared-daemon contention
benchmark:

```bash
ORIENT_DAEMON_CONTEND_ROOT=/path/to/workspaces \
ORIENT_DAEMON_CONTEND_CWDS=/path/to/repo-a:/path/to/repo-b \
ORIENT_DAEMON_CONTEND_MODE=both \
tools/ci/orient_daemon_contention_perf.sh
```

Use [Benchmarking](docs/benchmarking.md) for the full benchmark matrix, including
single-repo fallback vs indexed search, wide workspace gates, cold first-touch
latency, warm daemon contention, and mixed search/read load.

## Build And Test

```bash
bazel build -c opt //:orient
bazel test //...
bazel run //:ci_full_test
bazel run //:ci_perf_gates
```

## Docs

- [Shared daemon guide](docs/shared-daemon.md)
- [Agent adoption](docs/agent-adoption.md)
- [Agent protocol](docs/agent-protocol.md)
- [Benchmarking](docs/benchmarking.md)
- [Storage and footprint](docs/storage-footprint.md)
- [Fast search roadmap](docs/fast-search-roadmap.md)
