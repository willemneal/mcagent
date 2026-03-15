# Security Review: mcagent Project

**Reviewer**: Miriam Al-Rashid, CTO (Security)
**Scope**: PROJECT.md (vision), PLAN.md (implementation plan), IDEAS.md (future features), and current source code
**Date**: 2026-03-15

---

## Executive Summary

NACK — The architecture has excellent security instincts in its vision (WASI sandboxing, COW isolation, capability-based tool permissions), but the implementation has critical gaps that must be closed before this runs in any environment handling real code. The path traversal mitigations are bypassable, the `AgentId` type accepts arbitrary strings including path separators, there is no authentication on the MCP server, and agent-created tools can compile and execute arbitrary Rust code with declared-but-unverified capabilities. I see a project that *wants* to be secure. I am here to make sure it actually is.

---

## What Excites Me

### 1. WASI Sandbox as a Security Primitive

The decision to run tools as WASM modules with preopened directories is genuinely good security architecture. The WASI capability model enforces filesystem scoping at the VM level — not by policy, but by the absence of ambient authority. A WASI module literally cannot open a file it was not granted access to. This is the right foundation.

The `SandboxPermissions` struct and the `build_permissions` function that maps tool metadata capabilities to preopened directories show that someone thought about least privilege. The validation that `net` capability requires `preview2` is a nice catch — it prevents accidental network access through the simpler `preview1` target.

### 2. COW Isolation via Git Worktrees

Using `git worktree` for per-agent isolation is elegant. Each agent gets a real filesystem path that external tools (cargo, rustc) can use without modification, while changes are isolated to a branch. The diff mechanism using `git diff --name-status HEAD` is sound for detecting what changed.

### 3. Docker Backend with Network Disabled

The Docker backend defaults to `--network=none`, `--memory=512m`, `--cpus=1`. This is good defense in depth. Even if a tool escapes the WASI sandbox, it lands in a network-isolated container with resource limits.

### 4. Budget Enforcement as a Safety Net

The budget system with `enforce_budget()` checks before every tool call is a reasonable DoS prevention mechanism. An agent that goes rogue burns through its API call or token budget and gets killed. The tiered warning/pause/kill model in the IDEAS doc is well-thought-out.

---

## What Concerns Me

### CRITICAL: `AgentId` Accepts Arbitrary Strings (Path Traversal, Command Injection)

This is the single most important finding in this review.

```rust
impl FromStr for AgentId {
    type Err = std::convert::Infallible;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(Self(s.to_string()))
    }
}
```

`AgentId::from_str` accepts *anything*. It is `Infallible`. This type is then used to construct file paths and git branch names:

```rust
let agent_path = agents_dir.join(agent_id.as_str());          // CowLayer::create
let branch_name = format!("mcagent/{}", agent_id);            // CowLayer::create
let container_name = format!("mcagent-{}", agent_id);         // DockerBackend
```

What does the attacker control? The `agent_id` parameter in every MCP tool call is a raw `String` that gets parsed via `agent_id.parse().unwrap()` in `get_agent()` and `destroy_agent()`. If an attacker controls the agent_id string (and they do — it comes from the LLM via MCP), they can inject:

- `../../etc/passwd` in file paths
- `--upload-pack=<cmd>` in git branch names
- Shell metacharacters in Docker container names

Yes, `AgentId::new()` generates UUIDs internally. But `AgentId::from_str()` is public, and every MCP tool that takes `agent_id: String` calls `.parse().unwrap()`. Never trust user input.

**Recommendation**: Add validation in `AgentId::from_str` that rejects any value containing `/`, `\`, `..`, spaces, or shell metacharacters. Allow only `[a-zA-Z0-9_-]`. Make `FromStr` return an error type, not `Infallible`. Document the invariant on the type.

### CRITICAL: Path Traversal Checks Are Bypassable via Symlinks

The `read_file` and `write_file` tools do this:

```rust
let file_path = agent.working_dir.join(&params.path);
if !file_path.starts_with(&agent.working_dir) {
    return err("Path traversal not allowed".to_string());
}
```

This check is necessary but insufficient. `starts_with` operates on the *lexical* path, not the *canonical* path. Consider:

- `path = "src/../../../etc/passwd"` — `join` produces `<working_dir>/src/../../../etc/passwd`, and `starts_with` returns `false`. Good, this case is caught.
- But: `path = "symlink_to_root/etc/passwd"` — if an agent creates a symlink inside its working directory that points to `/`, this check passes because the *lexical* path starts with `working_dir`, but the *resolved* path is `/etc/passwd`.

The agent *can* create symlinks because `write_file` does not check for symlinks, and the COW layer's `copy_dir` function copies files but does not prevent subsequent symlink creation.

**Recommendation**: Canonicalize both `file_path` and `agent.working_dir` using `std::fs::canonicalize()` before comparing. Better yet, use `file_path.canonicalize()` and check `.starts_with(agent.working_dir.canonicalize())`. Note: canonicalize requires the path to exist, so for `write_file`, canonicalize the parent directory and check that.

### CRITICAL: `create_tool` Allows Arbitrary Code Compilation and Execution

The `create_tool` MCP tool accepts raw Rust source code from the LLM and compiles it to WASM:

```rust
pub fn create_tool(&self, name: &str, source_code: &str) -> Result<PathBuf, McAgentError> {
    let source_path = self.tools_dir.join(format!("{name}.rs"));
    std::fs::write(&source_path, source_code)?;
    self.compile_tool(&source_path)?;
    Ok(source_path)
}
```

The tool name is used directly in a file path with no validation. An agent could pass `name = "../../bin/evil"` and write a file outside the tools directory.

More importantly, the source code declares its own capabilities via frontmatter:

```toml
[package.metadata.wasi-tool.capabilities]
read = true
write = true
net = true
```

The runtime reads these capabilities and grants the corresponding sandbox permissions. This means a tool declares what it needs and gets exactly that — but there is no policy enforcement on what an agent is *allowed to request*. An agent that should only have read access can create a tool declaring `write = true` and `net = true`, compile it, and run it.

The compilation step also runs `cargo build` on the host system (not inside a sandbox). A malicious `build.rs` in the generated manifest could execute arbitrary host commands during compilation.

**Recommendation**:
1. Validate `name` in `create_tool` — alphanumeric, hyphens, underscores only.
2. Introduce a capability allowlist per agent. An agent's declared maximum capabilities should be checked against what its tools request. If a tool requests `net = true` but the agent is not authorized for network access, reject it.
3. Run `cargo build` inside a sandboxed environment (Docker or a separate WASI sandbox) to prevent `build.rs` attacks during compilation.

### HIGH: `compile_tool` Source Path Is Not Validated

```rust
async fn compile_tool(&self, Parameters(params): Parameters<CompileToolParams>)
    -> Result<CallToolResult, rmcp::ErrorData> {
    let state = self.state.read().await;
    match state.wasi_runner.compile_tool(std::path::Path::new(&params.source_path)) {
        Ok(wasm_path) => ok(format!("Compiled to {}", wasm_path.display())),
        Err(e) => err(format!("{e}")),
    }
}
```

`source_path` comes directly from the LLM with no validation. An attacker could point this at any file on the host filesystem. While `ensure_compiled` reads the file and tries to parse it as a Rust tool, even the act of reading arbitrary files is an information disclosure vulnerability (the error messages will reveal whether files exist and contain valid TOML frontmatter).

**Recommendation**: Restrict `source_path` to be within the tools directory. Reject absolute paths. Canonicalize and prefix-check.

### HIGH: No Authentication on MCP Server

The MCP server binds to stdio with no authentication:

```rust
let service = server.serve(rmcp::transport::stdio()).await?;
```

Any process that can write to the server's stdin can create agents, read/write files, compile and run tools, push branches, and create PRs. In the current architecture (CLI integration), this is acceptable because the parent process (Claude Code, Cursor) is the trust boundary. But the PROJECT.md mentions "SSE for web-based agent UIs" as a future transport. The moment this server is exposed over a network, the lack of authentication becomes a P0.

**Recommendation**: Design the authentication model now, even if you only implement it for stdio. Document the threat model: who connects to this server, what are they authorized to do, and how is identity verified. When SSE transport is added, require authentication tokens with constant-time comparison.

### HIGH: Error Messages May Leak Filesystem Structure

Throughout the codebase, error messages include full paths:

```rust
Err(e) => err(format!("Failed to read {}: {e}", params.path)),
```

The `params.path` is the user-supplied path, and `{e}` is the OS error which may include the resolved absolute path. An attacker can probe the filesystem structure by requesting paths and observing error messages. This is information disclosure.

**Recommendation**: Log the full error internally with `tracing::warn!`, but return a generic error to the caller: `"File not found"` or `"Permission denied"`. Never echo user-supplied paths back in error messages without sanitization.

### MEDIUM: `search_recursive` Has No Depth or Result Limit

```rust
fn search_recursive(dir: &Path, base: &Path, pattern: &str, matches: &mut Vec<String>) {
```

This function walks the entire filesystem subtree with no depth limit and no result cap. A malicious agent could request a search in a directory with millions of files and cause memory exhaustion or CPU starvation. The `pattern` is also a literal string match (`line.contains(pattern)`), not a regex — but there is no length limit on the pattern itself.

The function also follows symlinks by default (via `entry.path().is_dir()` and `entry.path().is_file()`, which follow symlinks). A symlink loop or a symlink pointing outside the sandbox would cause problems.

**Recommendation**: Add a max depth (e.g., 20), a max results count (e.g., 1000), a max file size to scan (e.g., 1MB), and use `symlink_metadata` instead of `metadata` to detect and skip symlinks.

### MEDIUM: `diff_filesystem` Follows Symlinks

In `CowLayer::diff_filesystem`, the `walkdir::WalkDir` uses default settings which follow symlinks. If an agent creates a symlink inside its working directory pointing to a sensitive location outside the sandbox, the diff would read and compare files outside the sandbox.

The PROJECT.md ideas document mentions this concern:

> Consider using `walkdir` with `follow_links(false)`.

This is already identified — it just needs to be done.

**Recommendation**: Set `follow_links(false)` on all `WalkDir` instances. Add a test that verifies symlinks pointing outside the agent directory are not followed.

### MEDIUM: `std::mem::forget(cow_layer)` in Docker Backend

```rust
std::mem::forget(cow_layer);
```

This prevents the CowLayer from being dropped, which is intentional (it is reconstructed later from paths). But if `destroy()` is never called (server crash, OOM, etc.), the COW layer is leaked with no cleanup. Over time, this accumulates orphaned worktrees and branches.

**Recommendation**: Implement a startup cleanup routine that scans `.mcagent/agents/` for orphaned worktrees and removes them. Also consider using `ManuallyDrop` instead of `forget` to make the intent explicit and greppable.

### LOW: Budget Enforcement Is Check-on-Entry Only

Budget is checked at the start of each tool call (`enforce_budget`), but the actual operation may consume resources beyond the budget. For example, `search_files` checks the budget, then does an unbounded recursive search that could consume arbitrary CPU time. The budget system is necessary but not sufficient for resource control.

**Recommendation**: For the WASI executor, consider using wasmtime's fuel metering to enforce CPU limits at the instruction level. For filesystem operations, add timeouts.

---

## What Is Missing

### 1. Threat Model Document

Where is the threat model? I see a well-architected system with clear security intuitions, but no document that says:

- Who are the threat actors? (Malicious LLM output, compromised agent, network attacker, insider)
- What are the trust boundaries? (MCP client -> MCP server, MCP server -> WASI sandbox, MCP server -> Docker container, MCP server -> host filesystem)
- What are the assets? (Source code, credentials in env vars, git history, GitHub tokens)
- What are the attack scenarios?

Without a threat model, security decisions are ad-hoc. The path traversal check in `read_file` exists but the same check is missing from `compile_tool`. This inconsistency is a symptom of missing systematic analysis.

**Recommendation**: Create a `THREAT_MODEL.md` that maps every trust boundary, every input source, and the validation required at each boundary. Review it quarterly.

### 2. Secret Detection

Agents read and write files. Agents produce diffs that get committed and pushed to GitHub. Where is the check that prevents an agent from committing a `.env` file, an API key embedded in source code, or a private key? The `commit_changes` tool commits whatever the diff contains with no content inspection.

**Recommendation**: Add a pre-commit content scanner. At minimum, check for common secret patterns (AWS keys, GitHub tokens, private keys, `.env` files). Reject commits that contain likely secrets. This is a blocking requirement before any automated push-to-GitHub workflow.

### 3. Rate Limiting on Tool Calls

Budget enforcement limits the total number of API calls, but there is no rate limit. An agent can make 100 API calls in 100 milliseconds. This is a DoS vector against the host system (100 concurrent file reads, 100 concurrent docker exec commands, etc.).

**Recommendation**: Add per-agent rate limiting (e.g., max 10 tool calls per second). Implement as a token bucket in `enforce_budget`.

### 4. Audit Log

There is no audit log of what agents do. If an agent reads `/etc/passwd` (via a path traversal vulnerability), how would you know? The budget system tracks counts but not the content of operations.

**Recommendation**: Log every tool invocation with agent_id, tool name, parameters (with secrets redacted), and result status. Write to an append-only file in `.mcagent/audit.jsonl`. This is table stakes for any multi-agent system.

### 5. Input Validation on `name` and `branch_name` Fields

The `AgentConfig` has `name: String` and `branch_name: Option<String>` that come directly from the LLM. These are used in log messages, branch names, and displayed to users. There is no validation that they are reasonable strings. A malicious `name` could contain terminal escape sequences (ANSI injection), newlines (log injection), or shell metacharacters.

**Recommendation**: Validate all string inputs from the MCP client at the tool handler boundary. Define a `SafeString` type that rejects control characters, shell metacharacters, and strings over a reasonable length (e.g., 128 chars).

### 6. Capability Model for the IDEAS Features

The IDEAS.md proposes agent-to-agent communication, cross-repo orchestration, and persistent memory. Each of these introduces new trust boundaries:

- **Agent-to-agent messaging**: Can agent A impersonate agent B? Can agent A send messages to a channel it should not access? What if a message payload contains path traversal or injection payloads?
- **Cross-repo orchestration**: Forking repos to an org requires GitHub tokens with elevated permissions. Where are those stored? How are they scoped? What prevents an agent from using the fork token to access unrelated repos?
- **Persistent memory**: Can agent A read agent B's memory? Can an agent store a value that, when read by another agent, triggers an injection? (Think: stored XSS but for LLM agents.)

**Recommendation**: For each feature in IDEAS.md, write a threat model section before implementation begins. Define the trust boundaries, the capabilities required, and the validation at each boundary.

---

## Specific Recommendations (Priority Order)

1. **P0**: Validate `AgentId` at construction — reject path separators, `..`, shell metacharacters. Allow only `[a-zA-Z0-9_-]`.
2. **P0**: Canonicalize paths before prefix-checking in `read_file`, `write_file`, `list_directory`, `search_files`. Check for symlinks.
3. **P0**: Validate `name` in `create_tool` and `source_path` in `compile_tool`. Restrict to tools directory.
4. **P0**: Run tool compilation in a sandbox (Docker or isolated environment) to prevent `build.rs` attacks.
5. **P1**: Implement a capability allowlist per agent so tools cannot self-declare elevated permissions.
6. **P1**: Add a pre-commit secret scanner before any automated push.
7. **P1**: Write a `THREAT_MODEL.md` covering all trust boundaries.
8. **P1**: Add audit logging for all tool invocations.
9. **P2**: Design authentication model for MCP server (even if only implemented for network transports).
10. **P2**: Add rate limiting to `enforce_budget`.
11. **P2**: Set `follow_links(false)` on all `WalkDir` usage.
12. **P2**: Add depth and result limits to `search_recursive`.
13. **P2**: Sanitize error messages — never echo user input or internal paths to the MCP client.
14. **P3**: Replace `std::mem::forget` with `ManuallyDrop` and add orphan cleanup on startup.
15. **P3**: Add wasmtime fuel metering for CPU-level budget enforcement.

---

## Verdict

NACK — The vision is strong and the architectural choices (WASI, COW, capability-based permissions) are the right foundation for a secure multi-agent system. But the implementation has critical gaps: unvalidated `AgentId`, bypassable path traversal checks, self-declared tool capabilities with no policy enforcement, and unsandboxed compilation. These must be fixed before any agent runs against real repositories or pushes code to GitHub.

I want to approve this. Fix the P0s and the P1s, and I will.

Signed-off-by: cto-security-paranoid@mcagent
