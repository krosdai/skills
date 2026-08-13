# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal collection of Claude Code Skills. Skills are modular packages (SKILL.md + optional scripts/references/assets) that extend agent capabilities.

## Public Repository

This is a public repository. Other people are welcome to use `npx skills` to add skills from here, so repository contents must be safe to share publicly.

Do not include personal credentials, tokens, API keys, local filesystem paths, or any other private user-specific information in skills, scripts, references, assets, or documentation.

## Repository Layout

- `skills/` — Self-authored skills
- `.agents/skills/` — Third-party / upstream skills
- `.claude/skills/` — Symlinks that Claude Code reads from, pointing to either of the above

## Commands

```bash
pnpm lint              # ESLint + Prettier check
pnpm format            # Prettier + autocorrect (CJK spacing) auto-fix
pnpm lint:fix          # ESLint fix + format
```

## Git Hooks

- **pre-commit**: runs `pnpm lint:staged` (ESLint fix on `*.ts/*.tsx`, Prettier + autocorrect on all files)
- **pre-push**: requires `git-lfs`

## Skill Structure

Every skill has a `SKILL.md` with YAML frontmatter (`name`, `description`) and markdown body. Optional directories: `scripts/`, `references/`, `assets/`.

When adding a new self-authored skill, create it under `skills/<name>/` and symlink into `.claude/skills/`.

## Code Style

- Prettier: 96 char line width, double quotes, trailing commas, LF endings
- Biome: 96 char line width, space indent
- autocorrect: enforces CJK-ASCII spacing (e.g., "使用 Python 3.11")

## Cursor Cloud specific instructions

- This repo requires Node `>=24` (`package.json` `engines`); Cursor's default image ships Node 22. The committed `.cursor/` environment (Node 24 image + Corepack pnpm + `git-lfs` + `mise`) provides the correct toolchain. For local setup, follow the `mise install` + `pnpm install --frozen-lockfile` flow in `README.md`.
- There is no automated test suite; `pnpm lint` (see `## Commands`) is the full check.
- AutoCorrect is only available through `mise` (invoked as `mise run autocorrect:fix` or `mise x -- autocorrect`), not on `PATH` directly. `mise` needs the repo trusted once via `mise trust` before it will read `mise.toml`.
- Known pre-existing failure: `pnpm lint` fails on `main` because two committed files under `skills/video-generation/` are not Prettier-formatted. This is unrelated to the environment; `pnpm format` fixes them.
