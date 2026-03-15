# Review: mcagent — PROJECT.md, PLAN.md, IDEAS.md + Codebase

**Reviewer**: Ava Chen, CTO AI-Native Platform
**Date**: 2026-03-15
**Scope**: Architecture, API surfaces, type design, error contracts, LLM-friendliness

---

## What Excites Me

### The core thesis is right

Every API surface *will* be consumed by an LLM. mcagent is designed for exactly that world: agents connect via MCP, get isolated workspaces, and produce stacked PRs. The fact that you started with MCP as the only entry point — not a bespoke CLI that you will "eventually" expose to models — is the correct call. Most teams build for humans first and bolt on LLM support later; this project does the opposite. I respect that.

### BudgetStatus enum is genuinely good

```rust
pub enum BudgetStatus {
    WithinBudget { usage_percent: f64 },
    Warning { usage_percent: f64, dimension: String },
    Exceeded { dimension: String, limit: f64, actual: f64 },
}
```

Three variants. Named fields. Self-documenting. An LLM can match on `Exceeded` vs `Warning` vs `WithinBudget` without reading any docs. The `Exceeded` variant tells you *which* dimension and the exact numbers. ACK on this type.

### AgentState enum

Five clean variants, each a lifecycle phase. No `AgentState::Other(String)`. An LLM can reason about state transitions without ambiguity. The `Display` impl produces lowercase one-word strings — parseable and predictable. ACK.

### DiffKind enum

`Added`, `Modified`, `Deleted` — three variants, exhaustive, no room for interpretation. Exactly what this should be.

### WASI exit code constants

The `exit_codes` module with named constants (`INVALID_ARGS`, `FILE_NOT_FOUND`, `PERMISSION_DENIED`, etc.) plus a `TOOL_SPECIFIC_START` threshold at 100 is a well-thought-out convention. An LLM can branch on these without guessing.

### WasiTarget with explicit serde rename

`#[serde(rename_all = "lowercase")]` on `WasiTarget` is intentional, visible, and correct. An LLM reading the JSON schema knows it will see `"preview1"` or `"preview2"`, not `"Preview1"`.

---

## What Concerns Me

### 1. `IsolationHandle::backend_data: serde_json::Value` — the biggest type hole

This is an untyped JSON blob in a core public struct. Can an LLM parse this? No. The `DockerBackend` shoves `container_name`, `agent_path`, `base_path`, and `agents_dir` into it. The `WasiBackend` puts the same minus `container_name`. Both backends then extract fields by string key (`handle.backend_data["container_name"].as_str()`), and if the key is missing, you get a `McAgentError::Docker("missing container_name in backend_data")` — a stringly-typed error about a stringly-typed field.

Define a `BackendData` enum:

```rust
pub enum BackendData {
    Wasi {
        agent_path: PathBuf,
        base_path: PathBuf,
        agents_dir: PathBuf,
    },
    Docker {
        agent_path: PathBuf,
        base_path: PathBuf,
        agents_dir: PathBuf,
        container_name: String,
    },
}
```

Even if you use `#[serde(tag = "backend")]`, the enum variants give the LLM (and future backend authors) a finite set of shapes to expect. The type should explain itself.

NACK — `serde_json::Value` in a public-facing struct is a code smell for LLM consumption.

Signed-off-by: cto-ai-native@mcagent

### 2. `McAgentError::Other(String)` — the black hole

`McAgentError::Other(String)` is used in the WASI backend for three distinct failure modes: "empty command", "exec failed", and "missing base_path/agents_dir in backend_data". An LLM retrying an operation that returns `Other("exec failed: No such file or directory")` cannot branch on what went wrong. It is the same variant for a missing binary, a missing field in backend_data, and an empty command array.

Split this into specific variants. At minimum: `EmptyCommand`, `BackendDataMissing { field: String, backend: String }`, `ExecFailed { command: String, source: std::io::Error }`. Kill `Other`.

NACK — `Other(String)` is the `Error::Unknown` of this codebase. The type should explain itself.

Signed-off-by: cto-ai-native@mcagent

### 3. `McAgentError::GitButler(String)` and `McAgentError::Docker(String)` — stringly-typed backend errors

Both of these are `(String)` wrappers. The GitButler variant is used for four distinct situations: failed to run `but`, `but` returned non-zero, failed to parse `but` output, and CLI command construction failures. The Docker variant covers: docker create failed, docker start failed, docker exec failed, docker rm failed, missing backend_data fields, and empty command.

An LLM retrying a `GitButler("failed to parse \`but\` output: ...")` has no idea whether to retry the command or fix its input. These need to be enums or at least structured variants:

```rust
GitButlerCommandFailed { subcommand: String, stderr: String },
GitButlerOutputParseFailed { subcommand: String, raw_output: String },
GitButlerNotInstalled,
```

Stringly-typed is the enemy of machine-readable.

Signed-off-by: cto-ai-native@mcagent

### 4. `McAgentError::InvalidConfig(String)` — what was invalid?

Same pattern. Which config field? What was expected? What was received? If I'm an LLM trying to fix my `agent_create` call and I get `InvalidConfig("bad branch name")`, I have nothing to go on. Make it:

```rust
InvalidConfig { field: String, expected: String, actual: String },
```

Signed-off-by: cto-ai-native@mcagent

### 5. `BudgetStatus::Warning` and `BudgetStatus::Exceeded` use `dimension: String`

The `dimension` field is a free-form string. I count exactly seven valid values in `check_budget`: `"input_tokens"`, `"output_tokens"`, `"cpu_seconds"`, `"memory_mb_seconds"`, `"wall_clock_seconds"`, `"api_calls"`, `"work_hours"`. This is a classic case where a `BudgetDimension` enum should exist:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BudgetDimension {
    InputTokens,
    OutputTokens,
    CpuSeconds,
    MemoryMbSeconds,
    WallClockSeconds,
    ApiCalls,
    WorkHours,
}
```

Then `BudgetStatus::Exceeded { dimension: BudgetDimension, ... }`. An LLM can match on the enum. Right now it has to do string comparison against undocumented values.

Signed-off-by: cto-ai-native@mcagent

### 6. `estimate_task_budget` takes `complexity: &str` — should be an enum

The function matches on `"low"`, `"high"`, and falls through to medium for anything else. This means `estimate_task_budget("potato")` silently returns a medium budget. That's not a bug today — it's a design trap. An LLM generating tool calls has no schema constraint telling it the valid values. The `EstimateTaskBudgetParams` has `complexity: Option<String>` with a doc comment saying `"low", "medium", or "high"` — but doc comments are invisible in JSON schemas. Make it an enum:

```rust
#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum TaskComplexity {
    Low,
    Medium,
    High,
}
```

The JSON schema will then expose exactly three valid values. If you need docs to explain the type, rename the type (or in this case, make it an enum).

Signed-off-by: cto-ai-native@mcagent

### 7. `ArgSpec::arg_type: String` — a type system for types, as a string

`ArgSpec` describes tool arguments, and `arg_type` is a free-form `String`. What are the valid types? `"string"`, `"int"`, `"bool"`, `"path"`? An LLM generating an `ArgSpec` has to guess. This needs an `ArgType` enum, or at minimum an `#[serde(rename = "type")]` with an explicit set of valid values documented in the schema.

Right now, `#[serde(rename = "type")]` is present but only for JSON key naming — it does not constrain the value. What does this look like in the JSON schema? A raw string with no constraints. That is not self-documenting.

Signed-off-by: cto-ai-native@mcagent

### 8. `ExecOutput` does not derive `Serialize`/`Deserialize`

`ExecOutput` is `#[derive(Debug, Clone)]` only. If this struct ever crosses a serialization boundary (and it will — MCP tools return it as text), the shape is invisible to the JSON schema. It should derive `Serialize, Deserialize` with explicit `#[serde(rename_all = "snake_case")]` to signal intent.

Signed-off-by: cto-ai-native@mcagent

### 9. MCP tool responses are all unstructured text

Every tool in `tools/mod.rs` returns `CallToolResult` with a `Content::text(msg)` where `msg` is a hand-formatted string. For example, `agent_status` returns:

```
Agent abc12345:
  name: coder-01
  state: working
  branch: agent/abc12345
  task: implement feature X
Changes:
  modified src/main.rs
Budget: Warning { usage_percent: 85.0, dimension: "api_calls" }
```

This is human-readable but machine-hostile. An LLM parsing this output has to do regex extraction on an ad-hoc format. The MCP spec supports structured content — you should return JSON. Define response types:

```rust
#[derive(Serialize)]
struct AgentStatusResponse {
    agent_id: String,
    name: String,
    state: AgentState,
    branch: String,
    task_description: String,
    changes: Vec<FileDiff>,
    budget_status: Option<BudgetStatus>,
}
```

Then `Content::text(serde_json::to_string(&response).unwrap())`. The LLM gets parseable JSON, not a formatted paragraph. This is the single most impactful change you could make for LLM consumption.

Signed-off-by: cto-ai-native@mcagent

### 10. `AgentId` wraps a truncated UUID — collision risk and no validation

`AgentId::new()` takes the first 8 characters of a UUID v4. That is 32 bits of entropy — birthday collision at around 77,000 agents. More critically, `FromStr` accepts *any* string as a valid `AgentId`, including empty strings, strings with spaces, and strings containing path separators. Since `AgentId` is used directly in filesystem paths (`agents_dir.join(agent_id.as_str())`), this is a path traversal vector waiting to happen.

Add validation in `FromStr`. Reject empty strings, strings with `/` or `..`, and strings longer than some sane limit. Consider using the full UUID instead of truncating.

Signed-off-by: cto-ai-native@mcagent

---

## What's Missing

### 1. No `TaskId` usage anywhere

`TaskId` is defined in `types.rs` but never appears in any other file. The PLAN.md describes a `TaskGraph` with dependency edges, but there is no `Task` struct, no `TaskState` enum, no task-to-agent mapping. This is the biggest gap between PLAN.md and the implementation.

### 2. No `list_agent_templates` or `get_agent_template` tools

PLAN.md Goal 2 describes these, but they don't exist in the MCP tool surface. The agent template system (`.mcagent/agents/*/AGENT.md`) is the primary way the orchestrator discovers agent capabilities. Without it, agent creation is blind — the orchestrator has no schema for what agent types exist.

### 3. No conflict detection

PLAN.md Goal 5 mentions "conflict detection when COW layers overlap on the same files." This is critical for parallel agent workflows and is completely absent. When two agents modify the same file, the system has no way to detect this before commit time.

### 4. No structured tool output schema in MCP

The ToolMetadata type describes tool arguments and errors beautifully, but the MCP server does not expose this metadata to callers. An LLM connecting to the MCP server sees tool names and descriptions but not the `args` and `errors` arrays from frontmatter. The tool metadata should be surfaced either via a `describe_tool` MCP tool or embedded in the tool's JSON schema.

### 5. No error recovery patterns

The IDEAS.md mentions "agents can write new tools" and the codebase supports `create_tool`, but there is no pattern for what happens when a tool compilation fails mid-task. No retry budget, no fallback tool, no error → alternative-approach mapping. For an LLM-driven system, the error recovery contract is as important as the happy path.

### 6. No `orchestrate` meta-tool

PLAN.md Goal 5 describes an `orchestrate` tool that accepts a list of tasks and builds the graph. This is the highest-value tool for LLM consumption — it reduces a multi-step workflow to a single call. Without it, the orchestrating LLM must manually create agents, branches, and manage dependencies itself.

### 7. Cross-repo support is IDEAS-only

The multi-repo coordination in IDEAS.md (`repos.toml`, forking, cross-repo PRs) is genuinely interesting but has zero implementation foothold. No types, no placeholder tools, no `RepoReference` struct. If this is a future goal, at minimum define the types now so the schema is stable when the implementation arrives.

### 8. Memory system has no implementation

OpenViking Memory in IDEAS.md describes per-agent KV stores with vector embeddings. This is important for cross-session continuity. There are no memory types, no HNSW references, no placeholder MCP tools. If agents are going to learn from past failures (as the reputation/learning section suggests), the memory contract needs to exist even if the backing store is a flat file initially.

---

## Specific Recommendations

### Priority 1: Type the `backend_data` field

Replace `serde_json::Value` with a `BackendData` enum. This unblocks correct error handling in both backends and makes the `IsolationHandle` self-documenting. Every downstream consumer of `IsolationHandle` currently does `handle.backend_data["key"].as_str().ok_or_else(...)` — that pattern should not exist in a typed Rust codebase.

### Priority 2: Return JSON from MCP tools

Every tool currently returns formatted text. Switch to JSON payloads. Define response structs for each tool. This is the single change that most improves LLM consumption of the API. An LLM that gets `{"agent_id": "abc", "state": "working", "changes": [...]}` can reason about the response without parsing prose.

### Priority 3: Kill `McAgentError::Other(String)`

Replace every usage of `Other` with a specific variant. Audit `GitButler(String)` and `Docker(String)` for at least 2-3 sub-variants each. The error type is the LLM's primary feedback mechanism when something goes wrong — stringly-typed errors make retry logic impossible.

### Priority 4: Introduce `BudgetDimension` and `TaskComplexity` enums

Both are used as strings today with a fixed set of valid values. Both appear in JSON schemas via the MCP tool surface. Both should be enums so the JSON schema constrains valid inputs.

### Priority 5: Implement `list_agent_templates`

The agent template system is the bridge between "I have agent definitions" and "the orchestrator knows what agents exist." Without it, the MCP server has 17 tools but no way for an LLM to discover which agent archetypes are available. This is PLAN.md Goal 2 and should be next after the type cleanup.

### Priority 6: Add `FromStr` validation to `AgentId`

Reject empty strings, path separators, and absurdly long values. This is a correctness issue, not just a style issue — `AgentId` is used in filesystem paths.

---

## Overall Assessment

The architecture is sound. The layering (WASI -> COW -> GitButler -> MCP) is clean and the separation of concerns is right. The `ExecutionBackend` trait is well-designed — pluggable backends with a clear contract.

But the API surface is not yet LLM-ready. The combination of stringly-typed errors, untyped JSON blobs in core structs, free-form string fields where enums should exist, and human-formatted text responses means an LLM consuming this MCP server will spend most of its reasoning budget parsing ad-hoc formats instead of doing useful work.

The types are 70% there. The remaining 30% is where LLMs will stumble. Fix the `backend_data` blob, structure the MCP responses as JSON, and split the string-based error variants — and this becomes genuinely excellent.

NACK — types are partially self-documenting, errors are not yet parseable. The architecture earns an ACK; the API surface needs the changes above before it is LLM-consumable.

Signed-off-by: cto-ai-native@mcagent
