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
TASKS=(auth-refresh:codex api-pagination:grok) # "<id>:<lane>", one per independent task

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

# Resolve the codex account up front so the loop can check it before creating anything. No
# CLI flag selects it, and CODEX_API_KEY outranks it — `run_codex` drops that per invocation.
# A custom provider's own `env_key` outranks even that, so assert the resolved account with
# rule 5's `codex doctor` query before a wide run. See "CODEX_HOME selects the profile" below.
CODEX_HOME=${CODEX_HOME:-$HOME/.codex}; export CODEX_HOME

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
  "$TIMEOUT" -k 30s 30m env -u CODEX_API_KEY \
    codex exec --json --sandbox workspace-write \
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

for spec in "${TASKS[@]}"; do
  t=${spec%%:*} lane=${spec##*:}
  # Drop last run's artifacts for this task, or a skip leaves stale results that read as
  # this run's — the same trap the exit-codes truncation above avoids.
  rm -f "$LOG/$t".{jsonl,json,err,last.txt} "$LOG/$t".review.{jsonl,txt,err}
  # Check the brief BEFORE creating anything, or a missing one leaves an orphaned worktree
  # that makes every later re-run of this task fail at `add`.
  [ -s "$BRIEFS/$t.md" ] || { echo "$t no-brief" >> "$LOG/exit-codes"; continue; }
  # Every other precondition belongs here too, for exactly that reason — a worker that
  # cannot start must not leave a tree and branch behind. An unknown lane is one of them:
  # `${spec##*:}` returns the whole string when the colon is missing, and `run_<that>` would
  # die as 127 in the background, recording nothing and orphaning the tree.
  case $lane in
    codex | grok) ;;
    *) echo "$t bad-lane-$lane" >> "$LOG/exit-codes"; continue ;;
  esac
  # Only codex tasks need the account, so an all-grok fan-out runs fine without codex. Accept
  # either credential: a stored login, or CODEX_API_KEY where that IS the credential (CI,
  # typically) — in which case also drop `run_codex`'s `env -u`, and accept that the two then
  # bill differently. Never paper over a missing account by creating an empty auth.json.
  if [ "$lane" = codex ] && [ ! -f "$CODEX_HOME/auth.json" ] && [ -z "$CODEX_API_KEY" ]; then
    echo "$t no-codex-auth-in-$CODEX_HOME" >> "$LOG/exit-codes"; continue
  fi
  # Never launch a worker into a tree you failed to create — on a re-run the add fails
  # ("already exists") and an unguarded worker would edit whatever is sitting there.
  git worktree add "$WORKTREES/$t" -b "feat/$t" "$BASE" || {
    echo "$t skipped-no-worktree" >> "$LOG/exit-codes"
    continue
  }
  "run_$lane" "$t" &
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
`error` event, again on `turn.failed` — and _not_ in the `.err` file, which carries only
startup chatter. A
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

**`CODEX_HOME` selects the profile, but it does not defend it.** No CLI flag selects the
account: `-p/--profile` layers `$CODEX_HOME/<name>.config.toml`, which switches _config_ and
never credentials — even `--ignore-user-config` keeps reading auth from `CODEX_HOME`. What
`CODEX_HOME` cannot do is stop an environment variable outranking the profile you pinned.
Measured precedence in `codex exec`: a provider's own `env_key` beats **`CODEX_API_KEY`**,
which beats the stored ChatGPT login. Export `CODEX_API_KEY` and every worker bills metered
API from a profile whose `auth.json` still says `chatgpt` — so `unset` it, or launch through
`env -u CODEX_API_KEY`. That closes one rung, not the ladder: unless you pass
`--ignore-user-config`, a `model_provider` in `$CODEX_HOME/config.toml` can name an `env_key`
already sitting in your environment, and by the ordering above it wins anyway. Nothing in the
launcher can see that, which is why the pre-flight below asserts the resolved account instead
of trusting the guard.

`OPENAI_API_KEY` is _not_ that variable, which is worth knowing precisely because it looks
like it should be. On 0.146.0 the built-in `openai` provider sets no `env_key`, so exporting
`OPENAI_API_KEY` changes nothing about who pays: a bogus value produces byte-identical
behaviour to no value at all. It only flips `codex doctor`'s own HTTP probe, which is why
doctor can warn `mixed auth signals` on a run that is spending pure subscription quota.

That makes `codex login status` useless for this: it prints the same `Logged in using ChatGPT`
for every profile directory and says nothing about either variable. Read `codex doctor`
instead — and read the right row. `auth mode`, under Connectivity, is the credential a turn
actually spends; `reachability mode` describes only the probe, and `auth env vars present`
reports presence, never precedence:

```bash
# Mirror `run_codex`'s `env -u`, or you measure your own credential rather than the workers'.
env -u CODEX_API_KEY codex doctor --json |
  jq -r '.checks[]|select(.id=="network.websocket_reachability").details["auth mode"]'
```

Scope that to Lane A. On this build the app-server lane ignored `CODEX_API_KEY` and spent the
stored login anyway, while doctor still reported `api_key` — so treat the row as an answer
about `codex exec`, and keep the `unset` in both lanes rather than relying on the difference.

**Check the exit status, not just the output.** When `timeout` fires, codex is killed
mid-stream: the JSONL never reaches `turn.completed` and `-o` is never written, which looks
identical to a crash or a bad schema path. The exit code is the only signal: 124 when
SIGTERM ended it, 137 when `-k` escalated to SIGKILL (measured on GNU coreutils 9.4). Do not
lean too hard on 137 though — an OOM kill or a CI runner reaping the job produces it too.
Treat any non-zero code as "no usable result", then look for the reason in the JSONL first —
`turn.failed` and `error` carry it, and a schema rejection puts it there rather than in
`.err`. Fall back to `.err` only for failures that never reached the protocol at all — and
do not test it for emptiness, since it collects startup chatter regardless. Either way the
worktree still holds partial, uncommitted edits.

Keep stderr in its own file. Both machine-readable outputs are parsed structurally, so
folding diagnostics into them with `2>&1` corrupts the parse — and codex does write ordinary
chatter there, `Reading additional input from stdin...` on every redirected run for one.

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

**Rule 6 has a purpose-built lane on the codex side.** `codex exec review` reviews headlessly
and keeps the same `--json` / `-o` / `--output-schema` plumbing as `codex exec`. Because it
reads a diff rather than a conversation, it strips the implementer's self-assessment by
construction. It only satisfies rule 6 when codex is the _reviewer_ — when codex wrote the
code, the diff still goes to grok.

Three things about it will bite on first use:

```bash
# Parent-level flags go BEFORE `review` — the subcommand has no -C, -p, -s, --add-dir, -i.
# The spec rides in positionally, which is the only shape that carries spec AND diff (2 below).
# It is still a `codex exec` turn: no turn cap (rule 4), --json needs its own redirect, and
# the account guard applies here too — this lane runs once per reviewed task.
"$TIMEOUT" -k 30s 30m env -u CODEX_API_KEY \
  codex exec -C "$WORKTREES/$t" review \
  --json -o "$LOG/$t.review.txt" \
  "$(cat "$BRIEFS/$t.md")
Review the diff of HEAD against $BASE against that spec." < /dev/null \
  > "$LOG/$t.review.jsonl" 2> "$LOG/$t.review.err"

# codex exec review -C …            → error: unexpected argument '-C' found
# codex exec review --base X "spec" → error: the argument '--base <BRANCH>' cannot be used
#                                     with '[PROMPT]'
```

1. **The target and a prompt are mutually exclusive.** `--base`, `--uncommitted`, `--commit`,
   and a free-form `[PROMPT]` are four ways to name one `ReviewTarget`, so you get exactly
   one: `error: the argument '--base <BRANCH>' cannot be used with '[PROMPT]'` (exit 2). Flag
   ordering will not save you, and `-` reads as a prompt, so stdin is not a way around it.
2. **So `--base` cannot carry the spec** that rule 6 asks for. Use the prompt form instead and
   let the reviewer resolve the diff itself — `codex exec -C "$WORKTREES/$t" review "<spec>.
Review the diff of HEAD against $BASE."` A repo `AGENTS.md` also reaches the review turn
   (verified in its rollout), but that is the human-written channel of rule 7, not somewhere
   a supervisor writes a per-task spec.
3. **A `--base` that does not resolve fails quietly**, unlike the script's own `rev-parse`
   guard: codex swaps in a fallback prompt telling the model to work out the merge base, so a
   typo'd branch yields a plausible review of the wrong range. `--title` is silently dropped
   here too — it survives only on `--commit`.

`codex review` is a thinner subcommand, not an alias: no `--json`, no `-o`, no
`--output-schema`. For orchestration, always reach for `codex exec review`.

Also useful: `--ephemeral` and `--ignore-user-config` / `--ignore-rules` for hermetic runs,
`--strict-config` to make an unrecognized config key an error rather than a silent ignore,
`codex exec resume --last`, `grok --worktree=<name> --worktree-ref=<base>`
plus `grok worktree list|rm|gc`.

## Lane B

Lifecycle: `initialize` → `initialized` → `thread/start` → `turn/start` → notifications →
`turn/completed`. JSON-RPC 2.0 request/response/notification shapes, but the `jsonrpc: "2.0"`
version field is omitted — treat it as JSON-RPC-style, not a conformant JSON-RPC 2.0
endpoint, and do not send the field yourself.

The messages are the same on every transport; the _framing_ is not. Newline-delimited JSON is
`stdio://` only — everything below assumes it.

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
`ws://IP:PORT` for a supervisor that is not the server's parent — but **both speak WebSocket,
not newline-delimited JSON**. Write the stdio bytes at either and you get silence (unix) or
`HTTP/1.1 400 Bad Request` (ws); they want an RFC 6455 upgrade, after which each message is
one text frame and the newline stops being a delimiter. The cheap way out is
`codex app-server proxy --sock <path>`, which bridges your existing stdio client onto the
socket and does the upgrade for you.

Non-loopback `ws://` is not the open door it looks like: binding anything but loopback
_refuses to start_ without `--ws-auth capability-token` (plus `--ws-token-file` /
`--ws-token-sha256`) or `--ws-auth signed-bearer-token` (plus `--ws-shared-secret-file`). The
credential rides the upgrade's `Authorization: Bearer` header and a bad one gets a 401 before
any JSON-RPC, so `initialize` carrying no credential does not mean the surface is unguarded.
Requests arriving with any `Origin` header are refused outright, which shuts the browser and
DNS-rebinding path. What is genuinely exposed is confidentiality: there is no `wss://` and no
TLS flag, so prompts, diffs, and the bearer token itself travel in clear text — tunnel it, or
prefer `unix://PATH` when both ends share a host.

Loopback is the case to actually think about, because there the refusal does not fire: a
`ws://127.0.0.1` listener with no `--ws-auth` is unauthenticated by design, and on a
multi-user box every local account can reach that approval surface. Two fixes, both verified:

```bash
# Best — the socket is created srw------- (0600), so file permissions do the gating. Keep it
# on a private path: XDG_RUNTIME_DIR is unset on macOS and non-systemd hosts, and unguarded
# the path would collapse to unix:///codex-as.sock at the filesystem root.
codex app-server --listen unix://"${XDG_RUNTIME_DIR:-$HOME}"/codex-as.sock

# Or keep ws:// and authenticate it. --ws-auth is honoured on loopback too: without the
# header the upgrade gets 401, with it 101.
codex app-server --listen ws://127.0.0.1:7777 \
  --ws-auth capability-token --ws-token-file ~/.config/codex-as.token
```

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
  or exported as `CODEX_API_KEY`, which outranks the stored login — bills metered usage, so
  the same fan-out becomes cash. `codex doctor`'s `auth mode` row tells you which.
  `codex login status` does not.
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
   that means `codex doctor`'s `auth mode` row under the `CODEX_HOME` you are about to spend
   — not `codex login status`, which cannot distinguish profiles and hides a `CODEX_API_KEY`
   override — plus grok's `total_cost_usd` from the previous batch. A real quota figure needs
   `account/rateLimits/read`, which is Lane B; one short app-server handshake gets it without
   adopting Lane B for the actual work. That figure only describes the stored login, because
   the handshake ignores `CODEX_API_KEY` — so it is trustworthy exactly when the workers spend
   the same credential, which is what `run_codex`'s `env -u` guarantees. Drop that `env -u` and
   the number stops meaning anything: check `codex doctor`'s `auth mode` in the workers' own
   environment instead of reading rate limits at all.
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
