# Agent Instructions

This project uses **OpenSpec** (skills-based) for spec-driven development. Track non-trivial
work as OpenSpec changes under `openspec/changes/` rather than an external issue tracker.

For all software dependencies / tools - use the context7 MCP server to get the latest docs.

For features and implementation - focus on local first (e.g., k8s running in Tilt). For task
confirmation, ensure an automated test / script / justfile recipe exists that demonstrates the
change/behaviour. ALL tests must pass before a task is considered complete.

## OpenSpec Quick Reference

Use the slash commands (or equivalent skills):

- `/opsx:propose` – create a new change with proposal, specs, and tasks in one step
- `/opsx:explore` – think through ideas, clarify requirements before proposing
- `/opsx:apply` – implement the tasks in an approved change
- `/opsx:archive` – archive the change once deployed

CLI helpers:

```bash
openspec list              # active changes
openspec list --specs      # deployed capabilities
openspec show <item>       # view a change or spec
openspec validate --strict # validate everything
openspec archive <id> -y   # archive a completed change
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until
`git push` succeeds.

**MANDATORY WORKFLOW:**

1. **Capture remaining work** – open or update an OpenSpec change for any follow-up.
2. **Run quality gates** (if code changed) – tests, linters, builds.
3. **Update task checklists** – tick off completed items in `tasks.md`.
4. **PUSH TO REMOTE** – this is MANDATORY:

   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```

5. **Clean up** – clear stashes, prune remote branches.
6. **Verify** – all changes committed AND pushed.
7. **Hand off** – provide context for the next session.

**CRITICAL RULES:**

- Work is NOT complete until `git push` succeeds.
- NEVER stop before pushing – that leaves work stranded locally.
- NEVER say "ready to push when you are" – YOU must push.
- If push fails, resolve and retry until it succeeds.
