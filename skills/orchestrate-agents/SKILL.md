---
name: orchestrate-agents
description: >-
  Orchestrate codex and grok CLIs as parallel workers from a supervising agent session.
  Use when the user wants work fanned out across multiple coding agents, delegated to
  codex or grok, run in parallel worktrees, or cross-reviewed by a second model — e.g.
  "fan this out", "run these in parallel", "hand this to codex", "have grok write the
  tests", "orchestrate a few agents on this backlog". Covers choosing between one-shot
  process invocation and the persistent app-server lane, the exact headless flags,
  worktree isolation, budget and quota control, and cross-model review. Do not use for
  in-process subagents (use the Agent/Task tool) or for a single sequential task.
---

# Orchestrate agents: codex + grok

You are the supervisor. Decompose, delegate, verify, integrate. Keep architecture
decisions, merge ordering, and final review; delegate bounded implementation.

Fan out only as wide as you can actually review and land. Parallelism moves the
bottleneck from typing to reviewing — it does not remove it.

## Choose the lane

|                 | **Lane A — one process per task**                      | **Lane B — persistent app-server**          |
| --------------- | ------------------------------------------------------ | ------------------------------------------- |
| codex           | `codex exec --json`                                    | `codex app-server --stdio` (JSON-RPC-style) |
| grok            | `grok -p --output-format json`                         | `grok agent serve` / leader socket          |
| Setup           | none — a shell call                                    | ~150-line JSON-RPC client                   |
| Per-task cost   | reloads full system prompt (~20k tok codex, ~18k grok) | paid once per thread                        |
| Mid-run control | none: kill and restart, losing context                 | `turn/steer`, `turn/interrupt`              |

**Default to Lane A.** Reach for Lane B only when you need to correct a running agent
instead of restarting it, or when short tasks are frequent enough that the system-prompt
reload dominates. A task that writes a branch and exits is easier to retry and cannot be
left half-broken.

## Lane A

Each task gets its own git worktree and its own log. Launch them as background shell
processes, one per task, then collect results as they land — do not busy-poll.

```bash
mkdir -p "$WT/.agent" "$LOG"

# codex has no turn cap — `timeout` is the budget (rule 4 below).
timeout 1800 codex exec --json --sandbox workspace-write --ask-for-approval never \
  -C "$WT" --output-schema result.schema.json -o "$WT/.agent/last.txt" \
  "$(cat brief.md)" < /dev/null \
  > "$LOG/codex-$TASK.jsonl" 2> "$LOG/codex-$TASK.err"

grok -p "$(cat brief.md)" --output-format json --json-schema "$(cat result.schema.json)" \
  --max-turns 40 --permission-mode acceptEdits --cwd "$WT" \
  < /dev/null > "$LOG/grok-$TASK.json" 2> "$LOG/grok-$TASK.err"
```

Keep stderr in its own file. Both machine-readable outputs are parsed structurally, so
folding diagnostics into them with `2>&1` corrupts the parse — including the harmless
startup ERROR described under Gotchas.

`< /dev/null` is mandatory. With non-TTY stdin, codex appends whatever it finds as a
`<stdin>` block on your prompt; a spawned shell inherits stdin, so omitting it silently
corrupts the brief.

codex JSONL: `thread.started` → `turn.started` → `item.started`/`item.completed` →
`turn.completed` (carries `usage`); failures as `turn.failed` / `error`. Parse per line.
`--output-schema` and `-o` compose — stdout stays JSONL, `-o` gets final text. `-C` moves
the agent's working root but not the CLI's own path resolution: `--output-schema` is read
relative to the invoking shell, so a bare relative path is correct there while `-o` needs
an explicit `$WT/` prefix to land inside the worktree.

Also useful: `--ephemeral`, `--add-dir`, `--ignore-user-config` / `--ignore-rules` for
hermetic runs, `codex exec resume --last`, `grok --worktree=<name> --worktree-ref=<base>`
plus `grok worktree list|rm|gc`.

## Lane B

Lifecycle: `initialize` → `initialized` → `thread/start` → `turn/start` → notifications →
`turn/completed`. Newline-delimited JSON-RPC 2.0 request/response/notification shapes, but
the `jsonrpc: "2.0"` version field is omitted — treat it as JSON-RPC-style framing, not a
conformant JSON-RPC 2.0 endpoint, and do not send the field yourself.

Generate the protocol from the installed binary rather than trusting any list — it moves
between releases:

```bash
codex app-server generate-json-schema --out ./asproto
jq -r '.oneOf[]? | .properties?.method?.enum?[0]? // empty' \
  asproto/ClientRequest.json > methods.txt
```

What Lane B uniquely buys: `turn/steer` (inject correction mid-turn), `turn/interrupt`,
`thread/fork` (variants off a shared prefix), `account/rateLimits/read`, and
**programmatic approvals** — the server sends `item/commandExecution/requestApproval` and
`item/fileChange/requestApproval`, which you answer against your own policy instead of
running with `--dangerously-bypass-*`.

`thread/start` takes per-thread `cwd`, `sandbox`, `model`, `baseInstructions`,
`ephemeral`; `turn/start` takes per-turn `cwd`, `model`, `effort`, `outputSchema`.

One process does run threads concurrently, but with contention — four threads were
observed overlapping cleanly yet finishing non-linearly. Measure your own workload before
assuming N× throughput.

## Who gets what

- **codex** — well-specified repo-local implementation. Subscription-priced, so wide
  fan-out spends quota rather than cash. No turn cap: bound it with `timeout` externally.
- **grok** — bounded mechanical breadth: tests, repetitive multi-file edits, exploration.
  `--max-turns` gives a hard budget, and its JSON reports `total_cost_usd`. Metered, so
  watch the number.
- **you** — decomposition, the brief, worktree lifecycle, merge order, final review.

Write briefs as goal + constraints + acceptance criteria. Name the file scope explicitly
("only touch `src/auth/**`"). Specification ambiguity, not agent capability, is where
these runs fail.

## Non-negotiables

1. **One worktree per concurrent task.** Worktrees isolate code, not runtime — ports,
   `node_modules`, and lockfiles still collide. Never let two parallel tasks change
   dependencies.
2. **Branch names must satisfy the repo's ruleset** (commonly
   `^(build|ci|chore|docs|feat|fix|perf|refactor|style|test)/[a-z0-9]+(-[a-z0-9]+)*$`).
   Auto-generated worktree names usually do not comply — always pass an explicit name.
3. **Serialize git.** Diff before merge, merge one branch at a time, rebase the next onto
   the new base before reviewing it.
4. **Hard budgets always** — `--max-turns` on grok, `timeout` plus `turn/interrupt` on
   codex. Unbounded tool chaining is the classic way to burn an afternoon and a quota.
5. **Pre-flight the quota** via `account/rateLimits/read` before a wide fan-out.
6. **Whoever writes, someone else reviews.** Each model finds more bugs in the other's
   code than its own. Give the reviewer the spec and the diff — strip the implementer's
   own assessment, which measurably softens review depth.
7. **Never let an agent author `AGENTS.md`.** Human-written only; generated ones cost
   context and slightly reduce success.

## Gotchas worth knowing

- Every `thread/start` restarts the entire MCP server set (~20 servers with a heavy
  config). Thread creation is neither free nor fast — trim MCP for delegated work, or
  reuse threads instead of one-per-task.
- On Linux hosts with `kernel.apparmor_restrict_unprivileged_userns=1`, the app-server
  logs a bubblewrap/user-namespace ERROR at startup. It is a false alarm: codex falls back
  to its own Landlock/seccomp helper. Confirm with `codex doctor`, which reports the
  sandbox as active.
- Piping `jq` output straight into `wc`/`rg` has truncated non-deterministically. Write to
  a file first when a count matters.
- The three CLIs may already share global instructions (`~/.codex/AGENTS.md`,
  `~/.claude/CLAUDE.md`); `grok inspect` shows exactly what grok resolved. What is usually
  missing is a **repo-level** `AGENTS.md` — without one, delegates fly blind on project
  constraints. Adding it is the highest-leverage move before delegating in an unfamiliar
  repo.
