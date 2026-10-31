# Conductor (conductor.build, Melty Labs) — Research Notes

> Researched 2026-10-31 via conductor.build/docs (current), the HN thread (Show HN #44594584, Jul 2025, 115 comments / ~230 pts), legacy `conductor.json` reference, Charlie Holtz's setup-script gist, and third-party writeups.
> Purpose: understand the "worktree + setup script + chat" model to port it to Rex (terminal multiplexer).

---

## 0. Background

- Free native macOS app by Melty Labs (YC S24; Charlie Holtz + Jackson de Campos). Uses your existing Claude Code / Codex / Cursor / OpenCode logins — it is an orchestrator/GUI, not a model provider. Launch Show HN: "Conductor, a Mac app that lets you run a bunch of Claude Codes at once" (Jul 17, 2025). $22M Series A (Mar 2026). Now also has Conductor Cloud (Firecracker microVM sandboxes) and iOS, but the local Mac model is what matters here.
- Under the hood each task is a **git worktree**. Conductor never runs its own model; it spawns the agent CLIs as subprocesses with the workspace directory as their working directory.

---

## 1. The Conductor model: repo → workspaces ↔ chats

### Core hierarchy (from `docs/concepts/workspaces-and-branches`)

| Term | Meaning | Relationship |
|---|---|---|
| Project | Conductor's entry for a codebase; holds repo settings, scripts, instruction files, workspace list | 1 project : 1 repository |
| Repository | the Git codebase (existing local folder, GitHub repo, or quick-start). The original checkout stays the "project root" | 1 repo : many workspaces |
| Workspace | isolated copy for one task/issue/PR — **1 workspace maps to 1 branch** | each has its own working tree |
| Branch | checked out inside the workspace; the review/PR unit | 1 branch : 1 working tree (git's one-branch-one-worktree rule) |
| Running environment | app/server/test processes inside a workspace | 1 workspace can run many processes |

- Workspaces are created as **git worktrees** (fast, shared object DB — no re-clone) at `~/conductor/workspaces/<repo name>/<workspace name>`. A workspace gets a city-style *directory name* (e.g. `warsaw-v2`, `tokyo`) plus its branch name. New workspaces branch off the repo's configured base branch (e.g. `origin/main`) and **fetch from origin first**, so the workspace starts from the latest remote commit even if the local checkout is stale.
- **Key UX trick:** on workspace creation Conductor generates a temp-named branch, then *instructs the agent in the first chat to rename the branch to match the task* ("Conductor will instruct the agent to rename this branch to match what you're working on"). Branch naming is delegated to the chat, not typed by the user.
- One branch may be checked out in only one worktree; if you need the same work in two places, create a new branch via `git checkout -b <x>-2 <x>` or archive the old workspace. Existing branches/PRs/Linear+GitHub issues can seed a new workspace (⌘⇧N dropdown).

### Workspace ↔ chat mapping

- A **workspace is the container; chats (sessions) are attachable resources**. This is the crucial mental model — mirrors their API: `GET /v0/workspaces/{id}/sessions`, and `POST /v0/sessions` is literally "Add another agent chat to a workspace."
- A workspace holds **one or more chat threads**, each thread running one agent harness (Claude Code, Codex, Cursor, OpenCode). When you "start a new chat with Claude Code as the agent" inside a workspace, "the Claude session [stays] attached to the workspace's branch, terminal, diff, checks, and PR flow."
- **Multiple agents in ONE workspace** share the branch/files (implement + review, fix-tests-after-impl, compare approaches). **Multiple agents across workspaces** = independent tasks with independent PRs. Decision rule: "Use multiple workspaces when tasks should land independently. Use multiple agents in one workspace when the work shares the same branch, code state, and context."
- UI layout: sidebar lists projects→workspaces; each workspace view combines the chat composer area + a **bottom panel with tabs (Setup / Run / Terminal)** plus a **Diff viewer (⌘⇧D)** and a **Checks tab** (git status, CI, PR metadata, comments, todos). Changelog 0.46.0 confirms tabs persist ("New workspaces now open the same bottom panel tab (Setup/Run/Terminal) you last used"). Diffs/comments can be sent back into the chat (review comments become composer attachments; `@terminal` attaches terminal output to the composer). Checkpoints let you revert code changes *and* chat state together.
- Archive hides a workspace from the active list; History pane in the sidebar can restore it *including chat history*.

### Porting notes for Rex

- Conductor's primitive set maps almost 1:1 to Rex's existing worktree model: Project≈host repo checkout, Workspace≈`<project>/<name>` session, Setup script≈posts-worktree-create hook, Run/Actions≈per-session windows, legacy `conductor.json`≈your `worktree-sessions` state file.
- Notable structural points worth keeping: (a) workspace name is decoupled from branch name (branch derived from chat content), (b) multiple chats allowed per worktree, (c) sessions listed under a worktree, archived-but-restoreable list separate from active list, (d) new worktrees branch from `origin/<base>` after a `fetch --prune` rather than from the local root checkout.

---

## 2. Setup scripts

### Where they're configured

Three layers (precedence high→low; see `docs/reference/settings/user-project`):

1. Managed org settings `~/.conductor/settings.managed.toml` (enterprise only)
2. `<repo>/.conductor/settings.local.toml` — per-machine override, kept out of git
3. `<repo>/.conductor/settings.toml` — committed team defaults (runs only after merged to the default branch)
4. `~/.conductor/settings.toml` — user defaults across all repos
5. Built-in defaults

Also editable via the app UI (Settings → repo → Scripts tab), which writes the appropriate file. **Legacy:** repo-root `conductor.json` (older Conductor wrote scripts as a one-line string there; TOML superseded it in 2026; note "Older Conductor repositories may still have workspaces inside a `.conductor` folder under the repository root" — worktree location moved to `~/conductor/workspaces/`).

Modern `.conductor/settings.toml` shape:

```toml
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"
file_include_globs = """
.env.local
config/local.json
"""

[scripts]
setup = """
pnpm install
cp "$CONDUCTOR_ROOT_PATH/.env" .env
"""
archive = "./script/workspace-archive.sh"
run_mode = "concurrent"            # or nonconcurrent

[scripts.run.dev]                  # "actions" = Run-button commands
command = "pnpm dev --port $CONDUCTOR_PORT"
default = true
icon = "play"
available_in = [ "local", "cloud" ]
options.cwd = "packages/web"
```

Legacy equivalent (`conductor.json`): `{"scripts": {"setup": "npm install", "run": "npm run dev", "archive": "..."}, "runScriptMode": "concurrent"}`. Early Conductor (2025/HN era) used exactly this: a per-repo JSON with `setup`/`run` strings; originally people also just pasted a setup script path in the repo settings UI.

### When they run

- **Setup runs once per worktree creation**, right after git checks out tracked files in the new worktree — i.e. it's a *fresh-worktree initializer*, not an incremental sync. There is **no "incremental/update" setup in the core model**: if you change the setup script, existing workspaces don't re-run it; you'd rerun commands manually in that workspace's terminal or recreate the workspace. (Docs also suggest an optional fast-forward snippet inside setup purely to keep the *root* checkout current — again per creation.)
- Runs **synchronously in the workspace directory** before you start working; failures are surfaced as "Setup script failed" in troubleshooting with a dedicated **Setup tab** in the workspace bottom panel showing output (changelog: bottom panel tab Setup/Run/Terminal). Common failure listed in docs: setup expecting `.env` to appear automatically — the script must only depend on files that exist in the workspace (tracked files + Files-to-copy) or paths exposed through Conductor env vars.
- Script failures block a clean workspace; Conductor treats "workspace can't run" as repo-config debt and its docs push the quick-start prompt "create a workspace, paste this prompt, ask the agent to generate `.conductor/settings.toml`" (agent-authored config, reviewed via the diff viewer like any change).

### What a typical setup.sh does (real example — Conductor's own repo, cbh123 gist)

Charlie Holtz's gist `conductor_setup_script.sh` (their own desktop-app dev setup) shows the idiomatic pattern — every workspace becomes a fully independent instance of the app:

```bash
#!/bin/bash
WORKSPACE_NAME="${1:-...}"                       # space-unique identity
IDENTIFIER="com.conductor.app.dev.$WORKSPACE_NAME"

echo "Setting up Conductor development workspace: $WORKSPACE_NAME"
pnpm i                                            # deps per worktree
pnpm run build:sidecar                            # generated artifacts per worktree
mkdir -p "$HOME/Library/Application Support/$IDENTIFIER"   # per-workspace data dir

# per-workspace icon via ImageMagick (icon w/ workspace name overlay)
command -v magick && magick "$BASE_ICON" ... "$ICONS_DIR/icon.png"
```

Paired with an archive script that deletes exactly what setup created outside the worktree:

```bash
rm -rf "$HOME/Library/Application Support/com.example.app.dev.$CONDUCTOR_WORKSPACE_NAME"
```

Docs' recommended snippets: symlink env from root — `ln -s "$CONDUCTOR_ROOT_PATH/.env" .env`; keep root current — `git -C "$CONDUCTOR_ROOT_PATH" fetch --prune origin && git -C "$CONDUCTOR_ROOT_PATH" pull --ff-only || true`; workspace-unique ports via `CONDUCTOR_PORT`.

### Output & shell environment

- Setup/actions/terminals all run "from the workspace directory" and see Conductor's env vars. Conductor captures your environment by launching **an interactive login shell (`$SHELL`) inside the worktree** ("we use the workspace directory because tools like mise can change their behavior depending on the current directory"), then runs scripts with **zsh** non-interactively, with a **5-second timeout on shell-config load** (slow `.zshrc` = broken setup; docs tell you to put needed env directly in the script: `export PATH=...; eval "$(mise activate zsh)"`).
- Run-button actions run in a **process group**; Stop sends SIGTERM then SIGKILL to the group after 5s (non-configurable); scripts should be foreground supervisors, not `&`+daemonize.
- `scripts.run_mode`: `concurrent` (default; many workspaces can run actions simultaneously) vs `nonconcurrent` (starting an action stops others — for projects with one fixed port/DB/Docker stack).

---

## 3. Archive / cleanup behavior

- **Archive = retire a workspace** once its PR is merged (or dropped). 0.46.0 made it "instant" (previously synchronous cleanup) — archiving hides the workspace from the sidebar immediately.
- Before archiving, Conductor runs the optional **`scripts.archive`** script *inside the workspace dir* — its job is cleaning up resources **outside** the workspace directory (per-workspace app-support dirs, databases, named Docker containers...). Doc note: "If the script fails, archive may not complete."
- What happens to the worktree/branch:
  - The workspace disappears from the active list; the **History pane in the sidebar can restore it later, "including its chat history"** — so chat transcripts outlive the archive.
  - **`git.delete_branch_on_archive`** (settings key): optionally delete the workspace's branch.
  - **`git.archive_on_merge`**: automatically archive the workspace when its PR merges.
  - Conductor checks archiving to a `archives` category too — archived workspaces are still openable.
- Cloud workspaces: `POST /v0/workspaces/{id}/archive` = "Stop the workspace's machine and hide it in the app (restorable later)"; `unarchive` starts the machine again; plus a lighter `sleep` state (visible, resumable). Workspace lifecycle statuses: `initializing, ready, sleeping, archived…`.
- Branch-conflict UX: "A branch is already checked out" error suggests archiving the old workspace as one of the fixes. There was also a changelog fix "workspaces from merged PRs were archived immediately" (archiving on external merge is the designed behavior once PR is merged).

Porting note for Rex: archive = (1) agent can auto-run "archive script" equivalent, (2) keep chat/session metadata in a state file so an archived worktree can be restored/reopened, (3) optional branch deletion, (4) auto-archive on merge could hook a post-merge event.

---

## 4. Passing the worktree to the agent: cwd, env injection, "run arbitrary shell first"

- **cwd**: the agent subprocess (Claude Code binary) is spawned **with the workspace (worktree) directory as its working directory**. That alone is what binds the Claude session to the branch/files/diffs; everything else (terminal, diff, checks, PR) is attached around that same directory. Conductor bundles its own Claude Code/Codex binaries (`~/Library/Application Support/com.conductor.app/bin`) but you can point to the system one from PATH in Settings→Storage.
- **Env injection**: workspace terminals, agents, and scripts all receive:
  - `CONDUCTOR_WORKSPACE_PATH` — the worktree path
  - `CONDUCTOR_ROOT_PATH` — the repo root (main checkout); the escape hatch for scripts needing files outside the worktree (e.g. `cp "$CONDUCTOR_ROOT_PATH/.env" .env`, `ln -s ...`)
  - `CONDUCTOR_WORKSPACE_NAME` — display name (fallback = dir name); used to name per-workspace resources (`com.example.app.dev.$CONDUCTOR_WORKSPACE_NAME`)
  - `CONDUCTOR_DEFAULT_BRANCH` — target branch, usually `main`
  - `CONDUCTOR_PORT` — first of **10 contiguous ports allocated per local workspace** (so `CONDUCTOR_PORT..+9` via `$((CONDUCTOR_PORT+1))`); solves multi-workspace port collisions. Not set in cloud.
  - `CONDUCTOR_IS_LOCAL` (1/0), cloud-only: `CONDUCTOR_BASE_DIR`, `CONDUCTOR_API_URL`, `CONDUCTOR_API_TOKEN/KEY`, and `CONDUCTOR_SESSION_ID` (the chat/session the agent process belongs to; not visible to setup scripts or plain terminals)
  - Plus custom vars via `[environment_variables]` / `[environment_variables.local|.cloud]` in settings files (secrets go in `settings.local.toml`, don't commit).
- **Auth**: Claude Code uses the machine's existing login (`claude /login`), or Conductor can inject provider env vars (e.g. `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, Bedrock/Vertex keys) from Settings→Environment; setting them in Conductor or in the login shell that launched Conductor changes billing path. Streaming/permission model: agents run "with the same permissions as your user account" (Conductor CLI permission setting allows `all-commands` on the standard Claude Code approval).
- **"Run arbitrary shell before starting the chat"**: there is one hook — the **setup script on worktree creation**, plus Files to copy, both guarantee a prepared workspace before the first chat. There is *not* a per-chat pre-launch hook today.
- **Straight-up UX boundary**: run actions (`scripts.run`), terminals, the Review action ("send the current diff to the agent for review"), and PR drafting all operate *from/into the same workspace directory*, so the chat's cwd never diverges from the checked-out branch. Claude Code's own native `--worktree`/worktrees feature is referenced in docs as the same primitive ("Conductor uses `.worktreeinclude`-like patterns — Anthropic documents the same behavior for Claude Code worktrees").

---

## 5. Keeping per-worktree state consistent (`.claude/`, `node_modules`, `.env`)

Conductor's answer is a **three-tier division of labor**:

1. **Tracked files** — present automatically in the worktree (git worktree checkout). Nothing to do.
2. **Static gitignored local files → "Files to copy" / `.worktreeinclude`.** At each worktree creation Conductor copies every **gitignored** file from the *main checkout* that matches the pattern list (gitignore syntax, `!` negation, `**` globs).
   - Configured in app Settings or as `file_include_globs` in `.conductor/settings.toml`, or as a **`.worktreeinclude`** file at repo root (that file **wins** if both exist — shared with raw-git-worktree tooling; Anthropic/Claude Code documents the same convention for its native worktrees).
   - **Default pattern = `.env*`** — i.e. out of the box every new workspace gets your `.env`/`.env.local` copied if gitignored. If you add your own patterns you must re-add `.env*` yourself.
   - Only runs for **local Mac** workspaces; only for files git already ignores; never copies tracked files; explicitly *not* recommended for `node_modules`/`.next`/`dist`/`target`.
3. **Anything requiring commands → setup script**: deps install (`pnpm install`), codegen, symlinks (`ln -s "$CONDUCTOR_ROOT_PATH/.env" .env`), local DB init, per-workspace app-support dirs named with `CONDUCTOR_WORKSPACE_NAME`. Docs: make the setup script *create a workspace-specific resource* rather than sharing one dev instance.
   - Specifically: **`node_modules` etc. are never copied — they're reinstalled by setup.** Reasons docs give: large/machine-specific/stale; regenerating in a shared object DB is cheap.
4. **Machine-local secrets/overrides** go into `<repo>/.conductor/settings.local.toml` (gitignored) so they're defined once per machine, then injected into every workspace's env/agent.

`.claude/`-type config: Conductor itself reads your *global* Claude Code auth/Claude-preferences from `~/.claude` (sf the app uses "the Claude Code authentication available on your machine"), and its repo-level "Repository Settings" / instruction-prompt files (`[prompts] general/code_review` in settings.toml) are committed like CLAUDE.md — the `.claude/` project dir itself comes through as a normal tracked file of the worktree.

---

## 6. Misc facts that inform a Rex port

- Conductor started with a **`conductor.json` at repo root** ( Sherpa reached same shape as Rex's `worktree-sessions` state file — but then moved config *into the repo* so the whole team inherits it automatically (checked into git, effective after merge). This is probably the single biggest evolution worth copying: **worktree tooling config is project config**.
- Their recommendedSeller entry-point for configuring a repo: **have the agent itself write settings.toml from a prompt in a first workspace** (docs "Quick start: ask Conductor"), then review the diff like code.
- Conductor treats the **branch as another artifact of the chat**, not the workspace: rename via the chat on first start, rename via `git branch -m` anytime.
- Checkpoints feature: revert code changes *and* chat state together (revert a turn without corrupting the chat log).
- Archived workspace restore preserves chat history → implies transcripts stored per-workspace in app storage (`~/Library/Application Support/com.conductor.app` + `~/conductor`), not in the worktree (which gets cleaned).
- Known complaint (HN/Show Ghostree thread): GUI wrappers lag the agent CLI features; terminal-native workflows (Rex!) win on responsiveness and access to fresh CLI features. Conductor's counter-moves: diff-first UX, checks tab, instant archiving, env-var skyline (`CONDUCTOR_PORT`).
- Agent teams: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` env setting works, so Conductor doesn't block newer Claude Code features.

---

## 7. Sources

- docs (current, 2026): `/docs`, `/docs/first-workspace`, `/docs/concepts/{workspaces-and-branches,workflow,git-worktrees,parallel-agents}`, `/docs/reference/{scripts,files-to-copy,environment-variables,shells,conductor-json}`, `/docs/reference/settings/user-project`, `/docs/reference/harnesses/claude-code`, `/docs/guides/git-worktrees/run-claude-code-with-git-worktrees`, `/docs/guides/parallel-agents/run-multiple-claude-code-sessions`, `/docs/guides/review-and-merge`, `/docs/installation`, `/docs/troubleshooting/issues`, `/docs/faq`, `/docs/api`
- changelog: `/changelog/0.46.0-bug-fixes-instant-archiving-terminal` (bottom-panel tabs, instant archiving, @terminal, fix for setup scripts hanging)
- YC launch post (conductor.build "Run a bunch of Claude Codes in parallel")
- Show HN thread #44594584 (Jul 2025, 115 comments); Algolia HN search
- Gist cbh123/10b4e522252eb9d900872921fbeb736d (the reference setup script example linked from official docs)
- Starter project repo `meltylabs/Starter-Project` (README showing shipped `.conductor/settings.toml`)
- Third-party: continuumcode.ai/what-is-conductor, collabs-inc/research-notes Conductor.md, yetanotherorchestrator.app/apps/conductor, porter gist by cacoos (conductor.json + CONDUCTOR_PORT pattern)
