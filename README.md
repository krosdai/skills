# xdanger.skills

Personal collection of [Claude Code Skills](https://docs.anthropic.com/en/docs/claude-code/skills) for extending AI agent capabilities.

## Skills

| Skill                                               | Description                                                             |
| --------------------------------------------------- | ----------------------------------------------------------------------- |
| [git-commit](skills/git-commit)                     | Conventional Commits + Gitmoji 标准化原子提交                           |
| [audience-aware-comms](skills/audience-aware-comms) | 受众感知沟通：面向解读型读者（人或下游 AI agent）校准书面输出           |
| [deep-dive](skills/deep-dive)                       | 结构化深度学习：前置铺垫、分层讲解、机制准确的记忆钩子与延伸路径        |
| [browser-automation](skills/browser-automation)     | 统一浏览器自动化，支持 agent-browser 与 playwright-cli 双路径           |
| [manus](skills/manus)                               | 异步任务代理，适用于 PDF/PPT/CSV 生成等超出本地工具能力的任务           |
| [video-generation](skills/video-generation)         | Seedance 2.0 AI 视频生成，支持文生视频、图生视频、多模态参考与视频编辑  |
| [pr-shepherd](skills/pr-shepherd)                   | 全自动护送 PR 到合并：修复 CI、回应评审、严格门禁校验后合并并清理       |
| [orchestrate-agents](skills/orchestrate-agents)     | 编排 codex / grok CLI 并行开发：通道选择、worktree 隔离、预算与交叉评审 |

## Usage

```bash
npx skills add https://github.com/xdanger/skills --skill git-commit
npx skills add https://github.com/xdanger/skills --skill audience-aware-comms
npx skills add https://github.com/xdanger/skills --skill deep-dive
npx skills add https://github.com/xdanger/skills --skill browser-automation
npx skills add https://github.com/xdanger/skills --skill manus
npx skills add https://github.com/xdanger/skills --skill video-generation
npx skills add https://github.com/xdanger/skills --skill pr-shepherd
npx skills add https://github.com/xdanger/skills --skill orchestrate-agents
```

## Structure

```
├── skills/                  # Self-authored skills
│   ├── git-commit/
│   ├── audience-aware-comms/
│   ├── deep-dive/
│   ├── browser-automation/
│   ├── manus/
│   ├── video-generation/
│   ├── pr-shepherd/
│   └── orchestrate-agents/
├── .agents/skills/          # Third-party / upstream skills
│   ├── git-commit/
│   └── skill-creator/
├── AGENTS.md                # Agent instructions
└── CLAUDE.md                → AGENTS.md
```

## Development

Install [mise](https://mise.jdx.dev/installing-mise.html). After reviewing `mise.toml`, trust
the repository configuration and provision the pinned AutoCorrect release and JavaScript
dependencies:

```bash
mise trust
mise install
pnpm install --frozen-lockfile
```

Run `pnpm lint` to check the repository or `pnpm format` to apply formatting fixes.

## License

Skills may have individual licenses. See each skill directory for details.
