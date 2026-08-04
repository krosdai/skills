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

One task = one worktree, one brief, one log, and exactly **one** worker. Two agents in the
same worktree is the collision rule 1 exists to prevent, so codex and grok below are
alternatives per task, never both on the same task.

```bash
TASKS=(auth-refresh api-pagination) # one id per independent task

# Keep worktrees and logs OUTSIDE the supervised repo — nesting them under it puts every
# delegate's tree inside your own working tree and pollutes status/ignore rules.
REPO=$(git rev-parse --show-toplevel)
RUN=${RUN:-$(dirname "$REPO")/.orchestrate/$(basename "$REPO")}
LOG=$RUN/logs BRIEFS=$RUN/briefs WORKTREES=$RUN/wt
mkdir -p "$LOG" "$BRIEFS" "$WORKTREES"
: > "$LOG/exit-codes" # truncate — otherwise a re-run reports two runs mixed together

# Branch off current upstream, and prove the base exists — an unresolvable ref would fail
# every `worktree add` and the run would look like a no-op instead of a misconfiguration.
git fetch -q origin || { echo "cannot fetch origin" >&2; exit 1; }
BASE=${BASE:-origin/main} # set BASE= where the default branch is not main
git rev-parse --verify -q "$BASE" >/dev/null || { echo "base '$BASE' not found" >&2; exit 1; }
# You write $BRIEFS/<task>.md first — goal, constraints, acceptance criteria, file scope.

# GNU timeout is the budget. macOS ships it as gtimeout via `brew install coreutils`;
# fail loudly here rather than letting every worker die with a confusing exec error.
TIMEOUT=$(command -v timeout || command -v gtimeout) ||
  { echo "no GNU timeout — macOS: brew install coreutils" >&2; exit 1; }

# CODEX_HOME picks which codex account the fan-out spends, and nothing else does. Workers
# inherit your environment, so naming it here is how you keep a wide run off the wrong
# profile's quota. See "Which codex account pays" below.
export CODEX_HOME=${CODEX_HOME:-$HOME/.codex}

# One result contract, consumed differently: codex takes a path, grok takes the text.
cat > "$RUN/result.schema.json" <<'JSON'
{
  "type": "object",
  "properties": {
    "summary": { "type": "string" },
    "committed": { "type": "boolean" },
    "files_changed": { "type": "array", "items": { "type": "string" } }
  },
  "required": ["summary", "committed", "files_changed"],
  "additionalProperties": false
}
JSON

run_codex() { # $1 = task id
  # codex has no turn cap, so `timeout` is the budget (rule 4). -k reaps a worker that
  # ignores SIGTERM; exit 124 means the budget fired, not that the task failed.
  "$TIMEOUT" -k 30s 30m codex exec --json --sandbox workspace-write \
    -C "$WORKTREES/$1" --output-schema "$RUN/result.schema.json" -o "$LOG/$1.last.txt" \
    "$(cat "$BRIEFS/$1.md")" < /dev/null \
    > "$LOG/$1.jsonl" 2> "$LOG/$1.err"
  echo "$1 $?" >> "$LOG/exit-codes"
}

run_grok() { # $1 = task id
  # --max-turns bounds turns, not wall clock — a stalled worker would hang the `wait`.
  "$TIMEOUT" -k 30s 30m grok -p "$(cat "$BRIEFS/$1.md")" --output-format json \
    --json-schema "$(cat "$RUN/result.schema.json")" --max-turns 40 \
    --permission-mode acceptEdits --cwd "$WORKTREES/$1" \
    < /dev/null > "$LOG/$1.json" 2> "$LOG/$1.err"
  echo "$1 $?" >> "$LOG/exit-codes"
}

for t in "${TASKS[@]}"; do
  # Drop last run's artifacts for this task, or a skip leaves stale results that read as
  # this run's — the same trap the exit-codes truncation above avoids.
  rm -f "$LOG/$t".{jsonl,json,err,last.txt}
  # Check the brief BEFORE creating anything, or a missing one leaves an orphaned worktree
  # that makes every later re-run of this task fail at `add`.
  [ -s "$BRIEFS/$t.md" ] || { echo "$t no-brief" >> "$LOG/exit-codes"; continue; }
  # Never launch a worker into a tree you failed to create — on a re-run the add fails
  # ("already exists") and an unguarded worker would edit whatever is sitting there.
  git worktree add "$WORKTREES/$t" -b "feat/$t" "$BASE" || {
    echo "$t skipped-no-worktree" >> "$LOG/exit-codes"
    continue
  }
  run_codex "$t" & # or run_grok "$t" — pick one per task
done
wait

cat "$LOG/exit-codes" # 0 = finished, 124 = budget fired, 137 = -k escalated, else failure
```

Tear down each task once you have merged or abandoned its branch — otherwise the next run
hits `already exists`, skips every task, and looks like a no-op:

**The branch has to go too, not just the worktree** — `worktree add -b` fails on an existing
branch, so a surviving `feat/$t` no-ops that task on every future run. Which delete you use
says what you decided:

```bash
git worktree remove "$WORKTREES/$t"
git branch -d "feat/$t"   # merged: -d refuses if it isn't, which is the point
git branch -D "feat/$t"   # abandoned: you are deliberately discarding the work
```

Lowercase `-d` guards the delegate's entire output, so a refusal means "this was never
merged", not "the command is broken". Use `git worktree remove --force` only after looking
at what is uncommitted — a dirty tree usually means the worker was killed mid-task and
nobody has reviewed it yet.

**codex validates `--output-schema` in strict mode.** Every key in `properties` must also
appear in `required`, and `additionalProperties` must be `false`. Omit one and the turn dies
with `invalid_json_schema` before any work happens. The reason lands in the JSONL — once as an
`error` event, again on `turn.failed` — and _not_ in the `.err` file, which stays empty. A
supervisor that reads only stderr sees a silent failure. Model optional fields as nullable
types, not as absent-from-`required`.

**The delegate commits; you review and merge.** Rule 3 assumes each task branch exists when
its worker exits, so say so in the brief. A linked worktree's `.git` is a gitfile pointing
into the main repo, but `workspace-write` still permits the commit — verified, no `--add-dir`
needed. Reach for `--add-dir` only when a task genuinely needs a second writable root; it
widens access rather than narrowing it.

**Autonomy differs by lane, so set it deliberately.** `codex exec` has no approval flag at
all — the sandbox mode _is_ the control, and passing `--ask-for-approval` there fails with
`unexpected argument` (it exists only on the interactive `codex`). grok's `--permission-mode`
is a separate axis: `acceptEdits` auto-approves edits and lets other tools follow your
permission rules, which in a headless `-p` run there is no TTY to answer. It ran non-edit
shell commands fine in testing, but local permission rules influence that. If a worker
stalls or quietly skips tests and builds, widen it with targeted `--allow` rules first.
Reach for `bypassPermissions` last and never bare: unlike codex, where `workspace-write`
still confines writes to the worktree, it drops the gate entirely for an unattended process
with shell access — a worker that misreads its file scope can reach the sibling worktrees of
your other parallel tasks. Pair it with `--sandbox` (or `GROK_SANDBOX`) so something is
still holding the boundary.

**Which codex account pays is `CODEX_HOME`, and only `CODEX_HOME`.** No CLI flag selects it:
`-p/--profile` layers `$CODEX_HOME/<name>.config.toml`, which switches _config_ and never
credentials — even `--ignore-user-config` keeps reading auth from `CODEX_HOME`. Where several
profiles are logged in on one machine, `codex login status` cannot tell them apart: it prints
the same `Logged in using ChatGPT` for every profile directory, and stays silent about an
`OPENAI_API_KEY` sitting in the environment — which applies no matter which profile you chose,
so a fan-out you believe is spending subscription quota can be billing metered API instead.
`codex doctor` is what discloses this, warning `mixed auth signals` and breaking out `auth env
vars present`, `stored auth mode`, and `reachability mode`. Pin `CODEX_HOME` per run rather
than trusting whatever the supervising shell inherited.

**Check the exit status, not just the output.** When `timeout` fires, codex is killed
mid-stream: the JSONL never reaches `turn.completed` and `-o` is never written, which looks
identical to a crash or a bad schema path. The exit code is the only signal: 124 when
SIGTERM ended it, 137 when `-k` escalated to SIGKILL (measured on GNU coreutils 9.4). Do not
lean too hard on 137 though — an OOM kill or a CI runner reaping the job produces it too.
Treat any non-zero code as "no usable result", read the `.err` file for the reason, and
remember the worktree still holds partial, uncommitted edits either way.

Keep stderr in its own file. Both machine-readable outputs are parsed structurally, so
folding diagnostics into them with `2>&1` corrupts the parse — including the harmless
startup ERROR described under Gotchas.

`< /dev/null` is mandatory. With non-TTY stdin, codex appends whatever it finds as a
`<stdin>` block on your prompt; a spawned shell inherits stdin, so omitting it silently
corrupts the brief.

codex JSONL: `thread.started` → `turn.started` → `item.started`/`item.completed` →
`turn.completed` (carries `usage`); failures as `turn.failed` / `error`. Parse per line.

**An `error` _item_ is not a failed turn.** A perfectly healthy run emits `item.completed`
carrying `item.type: "error"` for advisory notices (a truncated skill-description budget, say)
and still reaches `turn.completed` with exit 0. Judge the run on `turn.completed` versus
`turn.failed` plus the exit code; a supervisor that greps the JSONL for `error` condemns every
clean run.

`--output-schema` and `-o` compose — stdout stays JSONL, `-o` gets final text. `-C` moves
the agent's working root but not the CLI's own path resolution: both `--output-schema` and
`-o` are resolved against the invoking shell. Keep `-o` pointed at `$LOG`, outside the
worktree — an artifact written inside it leaves the tree dirty, and `git worktree remove`
then refuses without `--force`.

**Rule 6 has a purpose-built lane on the codex side.** `codex exec review --base "$BASE"`
reviews a branch against its base headlessly and takes the same `--json` / `-o` /
`--output-schema` plumbing as `codex exec`; `--uncommitted` and `--commit <SHA>` narrow the
scope instead. Because it reads a diff rather than a conversation, it strips the implementer's
self-assessment by construction. It only satisfies rule 6 when codex is the _reviewer_ — when
codex wrote the code, the diff still goes to grok.

Also useful: `--ephemeral` and `--ignore-user-config` / `--ignore-rules` for hermetic runs,
`--strict-config` to make an unrecognized config key an error rather than a silent ignore,
`codex exec resume --last`, `grok --worktree=<name> --worktree-ref=<base>`
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

That emits the stable surface only — 90 methods on 0.146.0. Add `--experimental` and roughly
thirty more appear (remote control, realtime audio, `thread/search`, `process/*`). Read them if
you are hunting for a capability, but do not build a supervisor on one: the flag exists
precisely because they move without notice.

`--stdio` is shorthand for `--listen stdio://`. `--listen` also takes `unix://PATH` and
`ws://IP:PORT`, which is what you want if the supervisor and the server are not
parent-and-child processes.

What Lane B uniquely buys: `turn/steer` (inject correction mid-turn), `turn/interrupt`,
`thread/fork` (variants off a shared prefix), `account/rateLimits/read`, and
**programmatic approvals** — the server sends `item/commandExecution/requestApproval` and
`item/fileChange/requestApproval`, which you answer against your own policy instead of
running with `--dangerously-bypass-*`.

`thread/start` takes per-thread `cwd`, `sandbox`, `model`, `baseInstructions`,
`ephemeral`; `turn/start` takes per-turn `cwd`, `model`, `effort`, `outputSchema`.

Neither takes an account: auth comes from the process's `CODEX_HOME`, so one server is one
profile, and a fan-out across profiles needs a server each. The `initialize` response echoes
`codexHome` back, which is the cheapest way to assert you attached to the one you meant.

One process does run threads concurrently, but with contention — four threads were
observed overlapping cleanly yet finishing non-linearly. Measure your own workload before
assuming N× throughput.

## Who gets what

- **codex** — well-specified repo-local implementation. No turn cap: bound it with
  `timeout` externally. Check the auth mode before sizing a fan-out: a ChatGPT-logged-in
  session spends subscription quota, but an API key — stored via `codex login --with-api-key`
  or merely exported as `OPENAI_API_KEY` — bills metered usage, so the same fan-out becomes
  cash. `codex doctor` tells you which, and warns when both are in play; `codex login status`
  does not.
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
5. **Pre-flight the budget** before a wide fan-out, by whatever the lane affords. In Lane A
   that means `codex doctor` under the `CODEX_HOME` you are about to spend — not `codex login
   status`, which cannot distinguish profiles and hides an `OPENAI_API_KEY` override —
   plus grok's `total_cost_usd` from the previous batch. A real quota figure needs
   `account/rateLimits/read`, which is Lane B; one short app-server handshake gets it without
   adopting Lane B for the actual work.
6. **Whoever writes, someone else reviews.** Each model finds more bugs in the other's
   code than its own. Give the reviewer the spec and the diff — strip the implementer's
   own assessment, which measurably softens review depth. When codex is the reviewer,
   `codex exec review` (Lane A) already works that way.
7. **Never let an agent author `AGENTS.md`.** Human-written only; generated ones cost
   context and slightly reduce success.

## Gotchas worth knowing

- Every `thread/start` restarts the entire MCP server set (~20 servers with a heavy
  config). Thread creation is neither free nor fast — trim MCP for delegated work, or
  reuse threads instead of one-per-task.
- Older codex builds logged a bubblewrap/user-namespace ERROR at app-server startup on Linux
  hosts with `kernel.apparmor_restrict_unprivileged_userns=1`. It was always a false alarm —
  codex falls back to its own sandbox helper — and 0.146.0 no longer emits it (checked on such
  a host: startup stderr was empty). If an older build still shouts, `codex doctor` settles it,
  reporting `sandbox  restricted fs + restricted network` plus the helper path.
- Piping `jq` output straight into `wc`/`rg` has truncated non-deterministically. Write to
  a file first when a count matters.
- The three CLIs may already share global instructions (`~/.codex/AGENTS.md`,
  `~/.claude/CLAUDE.md`); `grok inspect` shows exactly what grok resolved. What is usually
  missing is a **repo-level** `AGENTS.md` — without one, delegates fly blind on project
  constraints. In an unfamiliar repo this is the highest-leverage thing to fix first, but
  rule 7 still holds: surface the gap and ask the human to write it. Do not author it
  yourself, and do not let a delegate do it either.
