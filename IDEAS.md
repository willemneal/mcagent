# Ideas — Future Vision

## Meta Mono-Repo

A root repo with `.mcagent/repos.toml` listing sub-repos by GitHub URL. Tasks spanning repos fork each to the `model-c-agent` org, spawn a per-repo agent, and coordinate via PRs. Cross-repo deps tracked as PR references in commits.

```toml
# .mcagent/repos.toml
[[repo]]
name = "frontend"
url = "github.com/org/frontend"
branch = "main"

[[repo]]
name = "backend"
url = "github.com/org/backend"
branch = "main"
```

Cross-repo workflow:
1. Orchestrator receives task spanning multiple repos
2. Fork each repo to `model-c-agent` org (or use existing fork)
3. Spawn per-repo agent with isolated CowLayer/Docker backend
4. Each agent works independently, commits reference sibling PRs
5. Coordinator merges when all PRs pass CI

## `.mcagent/issues` + `.mcagent/prs`

Local markdown mirrors of GitHub issues/PRs for offline agent reasoning.

Format: `.mcagent/issues/123.md` with frontmatter:

```markdown
---
number: 123
title: "Fix timeout in auth middleware"
state: open
labels: [bug, auth]
assignee: agent-xyz
synced_at: 2026-03-14T12:00:00Z
---

Original issue body here...

## Comments

### @user (2026-03-13)
Seeing this in production with 5s timeout...
```

Synced by an MCP tool (`sync_issues`, `sync_prs`). Agents can read/reason about issues without GitHub API calls. Write-back creates comments or updates state via API.

## OpenViking Memory

Per-agent persistent memory in `.mcagent/agents/<name>/memory/`. KV store with vector embeddings for semantic search.

```
.mcagent/agents/coder-01/memory/
  index.json          # key → {value, embedding, timestamp, ttl}
  vectors.bin         # flat embedding storage for HNSW lookup
```

MCP tools:
- `memory_store(agent_id, key, value)` — stores with auto-embedding
- `memory_search(agent_id, query, limit)` — semantic search via HNSW
- `memory_list(agent_id, prefix)` — list by key prefix
- `memory_forget(agent_id, key)` — delete entry

Use cases:
- Agent remembers patterns it discovered in the codebase
- Agent tracks which approaches failed for a given problem
- Cross-session continuity — agent picks up where it left off

## Tool Creation Safety Progression

Docker now (good enough) → WASI components later (provably sandboxed).

### Current: Docker Mode
Agent-created tools compile and execute inside the container. No host compiler or filesystem access beyond the bind mount. Network disabled (`--network=none`). Resource-limited (`--memory=512m`, `--cpus=1`).

### Future: WASI Components
- Tools compiled to `.wasm` components with explicit capability declarations
- Capability model: filesystem (scoped paths), network (allowlisted hosts), env vars
- No ambient authority — all capabilities granted at instantiation
- Provably sandboxed — WASI component model enforces boundaries at the VM level
- Faster startup than Docker (~1ms vs ~100ms)
- Composable — tools can import other tool interfaces

Migration path:
1. Today: Docker backend executes tools, CowLayer provides file isolation
2. Next: WASI tools with capability declarations, Docker as fallback for native compilation
3. Later: Pure WASI — no Docker dependency, sub-millisecond tool startup

## Agent-to-Agent Communication

Structured message passing between agents via MCP tools:

- `send_message(from, to, channel, payload)` — async message
- `read_messages(agent_id, channel, since)` — poll for messages
- `broadcast(from, channel, payload)` — send to all agents on channel

Channels:
- `progress` — status updates ("50% done", "blocked on X")
- `discovery` — share findings ("found relevant code in src/auth.rs")
- `conflict` — flag overlapping changes ("I'm also editing config.rs")
- `review` — request peer review from reviewer agents

## Agent Reputation & Learning

Track agent performance over time:

```toml
# .mcagent/agents/<name>/stats.toml
[lifetime]
tasks_completed = 47
tasks_failed = 3
avg_review_score = 4.2
common_nack_reasons = ["missing tests", "style violations"]

[recent]
last_task = "implement-auth-middleware"
last_result = "approved"
reviewer_feedback = "Clean implementation, good error handling"
```

Use stats to:
- Route tasks to agents with best track record for that task type
- Adjust budgets based on historical resource usage
- Auto-select reviewer agents based on code area expertise

## Agent Hours Budget Tracking

Track and enforce time/cost budgets per agent, per task, and per project. Ties into the existing `Budget` struct in `mcagent-core` but extends it with wall-clock hours and billing dimensions.

### Budget Dimensions

| Dimension | Unit | Example Limit | Tracked By |
|-----------|------|---------------|------------|
| `wall_clock` | minutes | 60 min per task | Timer started at `create_isolation`, checked at each `exec` |
| `llm_tokens` | tokens | 500k input + 50k output | MCP server counts per request/response |
| `llm_cost` | USD | $2.00 per task | Computed from token counts × model pricing |
| `compute_seconds` | seconds | 300s CPU time | Docker `--cpus` × elapsed, or WASI fuel metering |
| `api_calls` | count | 100 MCP tool calls | Incremented per tool invocation |

### Config

Per-agent budget in `.mcagent/agents/<name>/config.toml`:

```toml
[budget]
wall_clock_minutes = 60
llm_input_tokens = 500_000
llm_output_tokens = 50_000
max_cost_usd = 2.00
compute_seconds = 300
max_api_calls = 100
```

Project-wide budget in `.mcagent/config.toml`:

```toml
[budget.project]
daily_cost_usd = 50.00
daily_llm_tokens = 10_000_000
concurrent_agents = 8

[budget.alerts]
warn_at_percent = 75
pause_at_percent = 90
kill_at_percent = 100
```

### Tracking & Enforcement

```
.mcagent/budget/
  ledger.jsonl        # append-only log of all budget events
  summary.json        # current totals, updated on each event
```

Ledger entry format:
```json
{
  "ts": "2026-03-14T12:34:56Z",
  "agent_id": "abc123",
  "task_id": "task-456",
  "dimension": "llm_cost",
  "delta": 0.0034,
  "cumulative": 1.47,
  "event": "tool_call",
  "detail": "exec: cargo test"
}
```

MCP tools:
- `budget_status(agent_id)` — current usage vs limits across all dimensions
- `budget_remaining(agent_id, dimension)` — how much headroom left
- `budget_report(scope)` — project-wide or per-agent summary
- `budget_adjust(agent_id, dimension, new_limit)` — orchestrator can raise/lower limits

### Enforcement Behavior

1. **75% warning**: Agent receives a system message: "You have used 75% of your wall_clock budget (45/60 min). Consider wrapping up or requesting a budget increase."
2. **90% pause**: Agent is paused, orchestrator notified. Orchestrator can extend or reassign.
3. **100% kill**: `destroy` is called on the isolation handle. Work-in-progress is preserved in the CowLayer for potential recovery.

### Billing Aggregation

Roll up agent-level costs to project dashboards:

```
Project: mcagent
  Today:   $12.47 / $50.00 daily limit
  This week: $43.21

  By agent type:
    coder:    $8.30 (67%)
    reviewer: $2.10 (17%)
    tester:   $2.07 (16%)

  By task:
    implement-docker-backend: $4.50 (3 agents, 2.1 hrs)
    fix-cowlayer-cleanup:     $1.20 (1 agent, 0.4 hrs)
```
