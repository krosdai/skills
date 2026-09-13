---
name: browser-automation
description: Operate a real browser for interaction, authenticated or dynamic content, screenshots, and UI verification, or when the user explicitly requests browser use. Static page reading or downloading alone does not require this skill.
allowed-tools: Bash(npx agent-browser:*), Bash(agent-browser:*), Bash(playwright-cli:*), Bash(npx playwright-cli:*)
---

# Browser Automation

Use this skill as the single entry for browser automation tasks.

Default to `agent-browser` for most work. Switch to `playwright-cli` only when the task needs
lower-level Playwright-style control.

## Default Workflow

Use this flow unless the task clearly needs a specialized branch:

1. `open`
2. `snapshot`
3. `interact`
4. `re-snapshot`
5. `verify`
6. `close`

Example:

```bash
agent-browser open https://example.com
agent-browser wait "#target-element"  # replace with the relevant page selector
agent-browser snapshot -i
agent-browser click @e1
agent-browser wait "#target-element"  # replace with the relevant page selector
agent-browser snapshot -i
agent-browser close
```

## Tool Selection

### Prefer `agent-browser`

Use `agent-browser` for:

- opening pages and navigating through a user flow
- clicking, typing, selecting, checking, scrolling, and uploads
- logging in and reusing saved browser state
- form submission
- taking screenshots, saving PDFs, or extracting page text
- scraping or capturing content with agent-friendly refs
- responsive checks, device emulation, and visual verification
- parallel browser sessions for agent workflows
- general website testing where snapshots and refs are enough

### Switch to `playwright-cli`

Use `playwright-cli` when the request explicitly needs:

- request mocking or routing
- tracing, video, console inspection, or network inspection
- explicit dialog accept or dismiss flows
- fine-grained mouse operations beyond normal click or hover flows
- explicit Firefox, WebKit, or Edge selection
- direct Playwright code execution with `run-code`

If the task starts as a normal browser flow and later needs one of the items above, switch tools
instead of forcing the whole task through `playwright-cli` from the beginning.

When both tools could work, prefer `agent-browser`.

## `agent-browser` Path

Prefer this path for most tasks because it is better suited to agent workflows.

```bash
agent-browser open <url>
agent-browser wait "#target-element"  # replace with the relevant page selector
agent-browser snapshot -i
agent-browser click @e1
agent-browser fill @e2 "text"
agent-browser select @e3 "option"
agent-browser check @e4
agent-browser get text @e5
agent-browser screenshot --annotate
agent-browser pdf output.pdf
agent-browser close
```

Good defaults:

- Use `snapshot -i` before interacting.
- Re-snapshot after navigation, form submission, modal open, or dynamic content changes.
- Wait for the target element, expected URL, or business result with a bounded
  timeout. Use `networkidle` only when network quiescence is itself required;
  background traffic need not prevent an otherwise ready page from being used.
- Use named sessions for parallel or long-running workflows.
- Use saved auth state when available.

## `playwright-cli` Path

Use this path only for tasks that clearly need Playwright-specific debugging or controls.

```bash
playwright-cli open https://example.com
playwright-cli snapshot
playwright-cli route "**/*.jpg" --status=404
playwright-cli console
playwright-cli network
playwright-cli tracing-start
playwright-cli tracing-stop
playwright-cli run-code "async page => await page.context().grantPermissions(['geolocation'])"
playwright-cli close
```

## Safety and Hygiene

- Keep the user-facing mental model simple. Do not ask the user to choose between the two CLIs
  unless they explicitly want a specific backend.
- Never expose secrets in commands when a safer auth or state flow exists.
- Prefer saved auth state or secure login helpers over typing passwords into shell history.
- Re-snapshot after navigation, form submission, modal changes, or any DOM update that can
  invalidate refs.
- Close the browser session when the task is complete so background state does not leak across
  tasks.
- Use named sessions to avoid collisions in concurrent agent work.

## Reusable Resources

- Template: `templates/form-automation.sh`
- Template: `templates/authenticated-session.sh`
- Template: `templates/capture-workflow.sh`
- Template: `templates/advanced-debugging.sh`
- Reference: `references/tool-selection.md`
- Reference: `references/session-auth.md`

These templates are starter workflows. Set `READY_SELECTOR` to a task-relevant
element before running a capture or form template. Choose it from
the page or an initial discovery snapshot; do not ask the user to choose a selector.
For authentication, set `LOGIN_READY_SELECTOR` and `AUTH_READY_SELECTOR` to
CSS selectors for the settled login form and authenticated landing content.
The saved-state path first waits for positive authenticated-content evidence.
If that bounded wait fails, it preserves the state file and inspects the login
form; a transient form or URL never invalidates saved state. Fresh login discovery
waits only for the login form. A generic body element does not establish that asynchronous content is
ready. Customize refs and follow-up commands for the site.

## References

Read these only when needed:

- For general browser workflows, auth, sessions, refs, and screenshots, read the upstream `agent-browser` skill:
  `https://github.com/vercel-labs/agent-browser/blob/main/skills/agent-browser/SKILL.md`
- For request mocking, tracing, network inspection, and Playwright-specific debugging, read the upstream `playwright-cli` skill:
  `https://github.com/microsoft/playwright-cli/blob/main/skills/playwright-cli/SKILL.md`
- For local routing rules and session guidance, read `references/tool-selection.md` and `references/session-auth.md`.

Load references only when needed. Keep the default path light.
