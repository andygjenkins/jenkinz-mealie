# Claude Code Instructions

## OpenSpec (spec-driven development)

This project uses [OpenSpec](https://openspec.dev) via the skills-based setup.

Use the `/opsx:*` slash commands (or the equivalent `openspec-*` skills) to:
- `/opsx:propose` – draft a new change with artifacts in one step
- `/opsx:explore` – think through ideas, clarify requirements
- `/opsx:apply` – implement the tasks in a change
- `/opsx:archive` – finalize and archive a completed change

Project planning context lives in `openspec/project.md` (legacy) and — going forward — the
`context:` section of `openspec/config.yaml`. Migrate content from `project.md` into
`config.yaml` as the repo evolves, then delete `project.md`.

Run `openspec update` periodically to keep the skills current.
