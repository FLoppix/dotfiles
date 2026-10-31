# Workrex — synthesized implementation plan (v2, arena result)

> Supersedes v1 of this document. Produced via a five-way design arena (four
> independent implementation specs + the v1 incumbent, cross-judged blind against
> a 6-criterion rubric). Base: **candidate-1 (workmux-faithful, 55/60)**; grafts
> from candidate-2 (Conductor-first, runner-up on UX), candidate-3 (minimalist,
> runner-up on scope) and candidate-4 (adversarial). Full candidates and the
> judge verdict live in `docs/research/`; the synthesis record (grafts,
> rejections, verification) is at the bottom of this file.
>
> Raw research: `docs/research/{workmux-core,workmux-agent,conductor}-notes.md`,
> `docs/research/arena/` (candidate plans + JUDGE.md).

## 0. TL;DR

`worktrees.lua` already replicates workmux's **skeleton** (session-per-worktree,
sibling `<project>__worktrees/<name>`, agent picker, open/remove). Workrex adds
what makes workmux + Conductor feel zero-friction:

| Feature | Source | v2 verdict |
|---|---|---|
| Per-repo committed config, sandboxed Lua | Conductor | `.workrex.lua` (+ optional `.workrex.local.lua`), loaded with a **capability-stripped env**; `<global>` list-splice from workmux |
| Gitignored file takeover + relative symlinks | both | `files.copy` default `{ ".env*" }` (Conductor rule: adding rules replaces the default); relative symlinks from the sibling-layout invariant |
| Long setup that beats the 30 s action budget | both | setup runs in a **visible setup window** (Conductor Setup tab); failure held on screen with in-pane Enter-retry; agent window is created **after setup succeeds, server-side** |
| Gating without sentinels/polling | c1 + c3 | setup pane self-reports to a server action `workrex_setup_done`, which adds the agent window via verified `session.new_window` and writes the `ok` marker **last** — "ok ⇒ agent exists" is an invariant, not a protocol |
| Lifecycle state in git config | workmux | `branch.<b>.workrex-base` written *before* `worktree add`; `workrex.worktree.<name>.*` for setup/agent/ports — diagnosable with one `git config --get` |
| Merge + one-command cleanup | workmux | `worktree_merge`: guards → streamed pipeline popup → quarantine-then-prune cleanup; cleanup failure never fails the merge |
| Env injection + 10-port block | Conductor | `WORKREX_*` env file sourced by every pane; `WORKREX_PORT..+9` |

Deliberately deferred (all candidates agreed): sandbox, remote hosts,
dashboard/sidebar TUI, agent status hooks, conversation fork/continue, PR
checkout, monorepo subdir configs, layouts DSL.

---

## 1. Verified Rex facts (the foundation — re-check these pins after Rex updates)

| # | Fact | Evidence |
|---|---|---|
| F1 | `rex window new -s SESSION [LABEL] [--focus=false] [-c DIR] [-- COMMAND…]` adds a window to a running session; `rex window ls -s SESSION` lists a session's windows | CLI `--help` |
| F2 | `session.create` accepts `initial_windows: null` / single-window array — a session can start with **setup only** | `rex api describe session.create` |
| F3 | Terminal block options have **no `env` field** (`additionalProperties: false`): `shell, command, args(dep), login, cwd, path_prepend, size, theme, initial_input, exit` | `rex api call block_creator.list` |
| F4 | `exit { on_completion = false }` keeps a block open after its program finishes; quick failures (<250 ms) stay open by default | creator schema |
| F5–F6 | `initial_input` types text into a block; block commands run **through the login shell** (normal PATH). Only `rex.exec` from actions has the minimal server PATH | creator schema + AGENTS.md gotcha |
| F7 | `rex call session.new_window { session_id (required), window_label, layout (required), focus }` — window creation in *any* named session, callable from Lua actions | `rex api describe session.new_window` |
| F8 | macOS has no `flock`/`setsid`; `sh` is bash 3.2; `nohup` exists | platform probe |
| F9 | Reusable verbatim from `worktrees.lua`: `run`/`run_ok` (:41–61), `repo_root` (:65–71), `worktree_paths` (:73–77), `valid_name` (:87–89), `rex_bin` (:176–206), `find_worktree_session` (:381–401), `remember/forget_session` (:365–377), `terminal_pane` (:117–128), `context.popup` (context.lua:74–91) | read |
| F10 | Pickers call `rex do -s "$session" <action>` and log failures to `~/.local/state/rex/worktree.log` (keep-error-until-Enter pattern) | worktrees.lua:594–617 |

**Key insight from the arena (F2+F7):** Rex can do workmux's ordering — provision
first, agent later. No sentinel polling, no polling gate, no daemon, no
`~/.local/bin` self-installers (all rejected by judgment / judge).

---

## 2. Files changed

```
dot_config/rex/
  worktrees.lua      EDIT   extended in place (~350 lines). All helpers stay file-local,
                            so a separate module would have to export or duplicate them.
README.md            EDIT   keymap table + Rex section (repo convention: keep in sync)
AGENTS.md            EDIT   Rex section: actions/keys/config/state
```

No new modules, no helper `.sh` files, nothing installed at runtime: every shell
script is a Lua-**generated string** passed as `sh -c <script> <args>…` — the exact
pattern `worktrees.lua` already uses for its fzf pickers. Zero new state-file formats.

## 3. Per-repo config: `.workrex.lua` (committed) — Conductor's lesson

```lua
-- <repo>/.workrex.lua — team defaults, review it like code.
-- Missing file ⇒ defaults == today's behaviour (+ default .env* symlink copy).
return {
  base          = nil,          -- nil = current branch at creation; e.g. "origin/main"
  branch_prefix = "wm/",        -- existing convention (worktrees.lua:76)
  worktree_dir  = nil,          -- nil keeps <project>__worktrees/<name> sibling

  files = {
    -- Conductor semantics: COPY gitignored files from the main checkout.
    -- Default when `files` absent: copy = { ".env*" }.
    copy    = {},               -- glob patterns, top-level only (validated)
    symlink = {},               -- made RELATIVE via the sibling-dir invariant
  },

  post_create = {},             -- FAST hooks, run at the top of the setup window
  setup       = {},             -- LONG commands (pnpm install …); Conductor Setup tab
  pre_merge   = {},             -- run in the SOURCE worktree before merge
  pre_remove  = {},             -- run in the live worktree before removal/archive

  env        = {},              -- extra exports into every workrex pane/agent
  port_block = 10,              -- 0 disables; WORKREX_PORT..PORT+9

  merge = { strategy = nil },   -- nil→"merge"; also "rebase" | "squash"
}
```

Layers, merged in this order (later wins scalars):

1. built-in defaults · 2. `<repo>/.workrex.lua` (committed, **sandboxed**)
3. `<repo>/.workrex.local.lua` (optional, appended to `.git/info/exclude` on
first load — never into tracked files).

There is no global config layer in v1. Add one when a second repository needs
shared hooks; the obvious name collides with the module.

Rex runs Lua 5.1, so the project loader uses `loadstring(text, "@.workrex.lua")`
followed by `setfenv(chunk, sandbox)` with a sandbox table holding only
`string`, `table`, `math`, `pairs`, `ipairs`, `tostring`, and `tonumber`. A repo
config **cannot execute host code** (no `os`, no `io`, no `require`), mirroring
workmux's distrust of project config. Unknown keys, bad strategy values, or
non-string hook entries abort the action **before any side effect**.

Defaults when `files` is present: adding any rule **replaces** the default
`.env*` rule (Conductor rule — re-add `.env*` yourself if you still want it).

## 4. Lifecycle state — git config, workmux-style

Written through helpers in `worktrees.lua` (per-key atomic `git config --local`;
no lock file — macOS has no `flock` (F8), the existing duplicate-name check at
worktrees.lua:448 excludes the only same-name race; documented):

| Key | Written | Meaning |
|---|---|---|
| `branch.<branch>.workrex-base` | **before** `git worktree add` | merge-target default; survives state-dir wipes |
| `workrex.worktree.<name>.base` | same moment | base actually created from |
| `workrex.worktree.<name>.session-id` | after create | rename-resilient session linkage |
| `workrex.worktree."<name>".setup` | `running → ok \| failed` | the state machine consumed by open/merge/remove. Quote subsections that contain dots, since `valid_name` allows them |
| `workrex.worktree.<name>.agent` | on add/rerun | last agent spec |
| `workrex.worktree.<name>.ports` | after allocation | first port of the block |
| `workrex.worktree.<name>.created` | create | ISO timestamp (picker display) |

The flat `~/.local/state/rex/worktree-sessions` map stays **as-is** and keeps
working (rename resilience already solved there); git-config values are written
alongside and consulted where the flat file has no answer (setup state, base,
ports). Old worktrees: lazy migration — every successful add/open backfills
keys; misses fall back to the existing detection chain.

## 5. The setup engine (the heart)

### 5.1 `worktree_add` — flow and budget

All steps except setup run inside the ≤30 s action; only `pnpm`-class commands
go to the setup window (worktrees.lua:16–17 guidance).

```
1.  valid_name, require_root, config load (fail-fast, pre-side-effect)
2.  duplicate check via find_worktree_session            (unchanged)
3.  base resolution: args.base > cfg.base > current branch of cwd
4.  set_base(root, branch, base)                         — BEFORE checkout (workmux order)
5.  git worktree add -b <prefix><name> <path> <base>     (worktrees.lua:454, timeout 20)
6.  set_meta(base, created)
7.  FILE OPS  (§5.3) — gitignore-filtered, idempotent; fail → rollback (step 11)
8.  PORTS     — allocate_port_block (§6.2); fail → continue with 0 (non-fatal)
9.  ENV FILE  — write <path>/.workrex/env + idempotent ".workrex/" → .git/info/exclude
10. set_meta(setup,"running"); set_meta(agent, spec)
    SESSION: session.create with windows [ setup(focused), nvim ] — NO agent window
    (F2: array of two is fine; F7 makes the agent window an a-posteriori addition)
    setup-block command = generated per-step script (§5.2), exit.on_completion=false (F4)
11. (*) rollback on any of 4–10: worktree remove --force + branch -D (unchanged
    pattern :458–464) + clear_meta + unset base
12. write_last_agent; remember_session; set_meta(session-id)
13. return { …, setup = "running"|"skipped", port, agent }
```

`no_setup=true` (CLI escape hatch) skips steps 7–10's window and restores
today's exact two-window session.

### 5.2 The setup window script — generated, per-step, self-healing

Built in Lua at call time from the *validated, quote-safe* config — no
`eval`-ing raw config, and each failure names its line (the Conductor
"Setup script failed" state, grafted from candidate-2). The pane reads its own
session from `$REX_SESSION`, which Rex exports into every block (Appendix A of
the phased plan), so the script needs no session id at generation time.

```sh
# generated — do not edit; edit the repo's .workrex.lua
cd "<worktree>" || exit 9
set -u
. ./.workrex/env || exit 9               # WORKREX_* + cfg.env exports

say(){ printf '\n[workrex] %s\n' "$1"; }
mark_failed(){ git -C "<root>" config --local 'workrex.worktree."<name>".setup' failed; }

run_steps() {
  say "post-create: <cmd1>"
  sh -c '<cmd1>' || { printf '\n[workrex] FAILED: <cmd1> (exit %s)\n' "$?"; mark_failed; return 1; }
  say "setup: <cmd2>"
  sh -c '<cmd2>' || { printf '\n[workrex] FAILED: <cmd2> (exit %s)\n' "$?"; mark_failed; return 1; }
}

ok=0
while :; do
  if run_steps; then ok=1; break; fi
  printf 'fix the problem, press Enter to retry, or Ctrl-D to abandon\n'
  read -r _ || break
done
[ "$ok" = 1 ] || exit 1

git -C "<root>" config --local 'workrex.worktree."<name>".setup' running
rex do -s "$REX_SESSION" workrex_setup_done name='<name>' agent='<spec>'
exec "$SHELL" -l            # pane always ends as a live shell (visible output, F4)
```

Failure-path properties:

- **Failure ⇒ agent never starts, structurally**: the `rex do` self-report sits
  below the loop exit; nothing else knows how to create the agent window.
- **ok-marker written last, server-side**: `workrex_setup_done` creates the
  agent window FIRST, then writes `setup=ok`. A window-create failure leaves
  `running`, one command away from a rerun.
- **Rerun from the same pane** (Enter — c3's graft) **or** new pane via
  `C-space>s` (`workrex_setup`, c1's graft, regenerates the script from current
  config).
- **User closes the window mid-install**: state stays `running`; any
  workrex_setup/open pass detects "running + no setup window in session
  (F1 `rex window ls -s`)" → treats it as abandoned and offers a fresh setup
  window (c4's closed-sentinel catcher without its polling machinery).
- Merge refuses `setup=running`; remove refuses `running` + uncommitted changes
  unless `force=true` (c4's guards).

### 5.3 File ops (action, ≤5 s; Conductor's gitignore tier)

Enumerate **once** with `git ls-files --others --ignored --exclude-standard` + a
pure-Lua glob matcher (`*`/`?` + `**`), then per matched path emit tiny `sh`
fragments (quote-safe positionals):

- **copy**: `mkdir -p $(dirname dst)`, `cp -pR src dst` (dirs recurse, symlinks
  preserved as links) — idempotent: skip when the destination
  exists (never overwrite user data; warn instead). Explicitly NOT for
  `node_modules`/`dist`/`target` — those are reinstall territory (`setup`).
- **symlink**: target precomputed in Lua from the sibling invariant (worktrees.lua:73–77):
  `../../<project>/<rel>` — **relative** links (workmux `pathdiff` semantics);
  `ln -sf` with target-validity + dedup guards.
- **default**: `copy = { ".env*" }` (Conductor), **plus** `symlink =
  CLAUDE.local.md` when that file exists and is gitignored (workmux's
  auto-symlink, grafted from c4's rule engine).
- Refuses patterns that escape the repo root; `git check-ignore` gates every
  candidate (tracked files never touched).
- Re-invokable: future `workrex_sync` just re-runs this pass (implemented as
  the same `fileops()` helper — v2.5 rollout).

### 5.4 `workrex_setup_done` (new internal action, the gate release)

```
args: name, agent
1. root from worktree list; path,branch via worktree_paths
2. session = find_worktree_session(path, label) (rename-safe, :381) — else error
3. DEDUP: `rex window ls -s <label> --json`; if a window labeled <agent> exists → { already = true };
   if a window labeled with the PREVIOUS agent exists → close it (`rex window close`) first
4. agent = agent_command(spec) (:104–115)  — window focus = false
5. add the agent window with `rex window new -s <label> <spec> --focus=false -c <path> -- <wrapped agent>`.
      The API call `session.new_window` returns 409 unless the control stream is attached
      to that session, so the action uses the CLI path through `rex_bin()` instead
6. set_meta(setup, "ok")   — LAST, after the window provably exists
```

## 6. Env injection + port block (F3: no env field ⇒ wrapper)

### 6.1 Env file + wrapper

`<path>/.workrex/env` (gitignored via `.git/info/exclude`):

```
export WORKREX_WORKSPACE_PATH=<worktree>   # Conductor WORKSPACE_PATH analog
export WORKREX_ROOT_PATH=<main checkout>
export WORKREX_WORKSPACE_NAME=<name>
export WORKREX_BRANCH=<wm/name>
export WORKREX_BASE_BRANCH=<base>
export WORKREX_PORT=<n>                    # block n..n+9
export WORKREX_PORTS="n:n+9"
# + cfg.env entries (placeholders {name},{branch},{root},{path},{port} expanded in Lua)
```

Every workrex-created window that needs env is wrapped (set `-a` = export):

```
sh -c 'set -a; . "$1/.workrex/env" 2>/dev/null; set +a; shift; exec "$@"' sh <path> <agent…>
```

Setup hooks, agent, nvim, and future run-panes read the same file — one source
of truth. `nvim` window command: wrapped plain (login PATH is automatic per F6).

### 6.2 Port allocation — counter + probe, no ledger file (c1's graft)

```
next = git config workrex.ports.next (default 31000)
candidate = next
for candidate → candidate+9 block: probe each port with /dev/tcp (one sh proc);
  any busy → candidate += port_block, retry (max 50)
git config workrex.ports.next = candidate + port_block
set_meta(ports, candidate)
```

No leases: the counter only advances (no reuse of a block a lurking dev server
still holds — deliberate); `set_meta` value survives crashes; remove clears
`workrex.worktree.<name>.ports` only. Cross-repo collisions handled by the probe
itself (the /dev/tcp busy test).

## 7. Merge / archive — workmux guards, Conductor streaming

### 7.1 `worktree_merge` (new; `C-space>m` + `worktree_merge_prompt`)

**Lua-side validation and assembly (fast, in-action):**

```
1. resolve: name | cwd's worktree (find_worktree_session) — refuse main root
2. self-session guard: source session == ctx.session → error "switch away, rerun"
   (worktrees.lua:543 guard — the consensus answer; no detached worker needed)
3. target = args.into > get_base(branch) > detected default branch
   (`origin/HEAD` trimmed; error if absent and no recorded base)
4. GUARDS (nothing destructive happened yet):
   - source `status --porcelain` uncommitted → error "{allow_dirty=true} to skip"
     (no staged auto-commit — candidate-3's refusal kept; the user commits)
   - target worktree tracked-changes (untracked allowed; git fails safely) → error
   - branch == target → error
   - meta setup == "running" → error "setup never finished; C-space>s first"
5. pre_merge hooks stay in the assembled script (below) — never in the action
   (a slow lint must not eat the action budget; candidate-2's insight, grafted)
```

**Execution = streamed pipeline popup** (c2's graft). The popup owns hooks,
strategy, and teardown, so a slow lint never eats the action budget:

```
context.popup script (bash in a pane — no budget, output streams):
  GUARDS re-verified (cheap; race evidence)
  for hook in pre_merge: . .workrex/env; (cd wt && eval "<hook>") || FAIL "hook <cmd>"
  merge | rebase | squash:
    merge:  git -C <targetwt> merge --no-edit <branch>
            conflict → git merge --abort → FAIL "resolve in <wt>, re-run merge"
    rebase: git -C <src> rebase <target>   — conflict aborts, "resolve in <src>";
            on success git merge --ff-only, then set_base(branch, target)
    squash: git merge --squash → conflict → git reset --hard → FAIL;
            then git commit -m "Merge <branch> (squash)"
  success → teardown chain → close (C-space>x not even needed; popup closes itself on success)
```

There is no headless twin. A scriptable `worktree_merge_apply` would double the
merge code for a need nobody has expressed, so the popup is the only path.

### 7.2 `worktree_remove` — pre-flight guards, quarantine cleanup

```
1. guards: self-session (:543); setup state (§5.2);
   `git status --porcelain` non-empty → refuse (c4: pre-flight so quarantine never
   silently eats diffs) unless force=true
2. pre_remove hooks: in the live worktree (workmux ordering), via the action's
   login-shell launch (:247–251 pattern) — timeout 25; hooks must stay short
3. session kill: rex_bin() kill (:552)
4. QUARANTINE (c1, workmux §2.8.2): mv <path> "<parent>/.workrex-trash-<project>-<name>"
   (repo-scoped, c2's name-collision fix) → git worktree prune → `nohup rm -rf` the
   trash in the background (an rm of node_modules can exceed the action budget).
   The trash dir is NOT a rescue location: prune drops its admin entry. The kept
   branch is the rescue, and `delete_branch=false` is the default on refusal.
5. forget_session + clear_meta
```

Conductor's `archive` hook and `pre_remove` are the **same hook** (c1/c2 agree:
"cleanup of resources the setup created" is exactly what pre_remove is). A
full History/restore flow (c2's `worktree_archive`/`worktree_restore`) is
**deferred**; revisit trigger: "removing worktrees to clear the picker without
losing branch context".

## 8. Keys & CLI surface

| Surface | args | key | notes |
|---|---|---|---|
| `worktree_add` (changed) | `name, agent?, base?, no_setup?` | `C-space>w` | §5.1 |
| `workrex_setup` (new) | `name?` | `C-space>s` | fresh setup pane; re-release path |
| `worktree_merge` (new) | `name?, into?, strategy?, allow_dirty?, keep?, squash_message?` | `C-space>m` | §7.1 popup |
| `worktree_remove` (changed) | `name, force?, delete_branch?` | `C-space>W` | quarantine path |
| `workrex_fix` (new, CLI-only) | `name?` | — | diagnose + heal (§5.2 abandoned case; stale mapping; missing agent window despite ok) |
| `workrex_setup_done` (new, internal) | `name, agent` | — | invoked by the setup pane (F7 verified in-action call) |

`m` and `s` verified free in the current prefix map (c1/c3 audited; all
candidates' keybinding additions checked against init.lua's taken set). Old CLI
verbs and pickers unchanged; worktrees.lua's log-file + Enter-on-error picker
pattern reused.

## 9. Verification checklist (Phase F of the rollout — one session, in order)

Machinery:
1. `chezmoi apply ~/.config/rex && rex config check && rex config reload`;
   `rex keymap` shows `w s o m W` (+ unchanged legacy); `rex actions | grep work`.
2. Schema pins: `rex api describe session.new_window`, `block_creator.list`,
   `rex window ls --help` — F1/F3/F7 still hold (defends against Rex drift).
Setup field trial (scratch repo with `.workrex.lua = { setup = { "pnpm install" } }`):
3. `rex do worktree_add name=t1 --json` → returns <5 s; session shows ONLY
   setup+nvim; watch setup stream; agent window appears after completion.
4. Failure path: `setup = { "false" }` → ▸ line, ✖ banner, `setup=failed`; NO
   agent window (`rex window ls -s <sid>`); Enter retried; Ctrl-D abandoned;
   `C-space>s` fresh pane; after fix the agent gate releases.
5. Closed-window path: close setup mid-install → next setup/open reports
   abandoned, offers rerun.
6. Dedup: double `rex do workrex_setup_done` → second returns already=true.
7. Marker invariant: `git config workrex.worktree.t1.setup` == ok **and**
   agent window present (write-after-create ordering).
Files/ports:
8. `.env` copied (gitignored-only proof: `git status` shows nothing);
   `readlink` resolves from a nested cwd (`web/`); node_modules symlink works.
9. t1 + t2 add → ports = block, block+10; `WORKREX_PORT` visible in penv.
Merge field trials:
10. happy path (merge); conflict → abort, target clean, branch alive; rebase ->
    abort path + rerun + ff; squash message via popup;
    `allow_dirty=1` bypasses the dirty guard and warns.
11. setup=running → merge refuses; keep=true path; branch -d refusal keeps
    the trash dir as rescue and keeps the branch.
Remove:
12. cleanup phases: t1 remove: preflight dirty (unless force), quarantine,
    prune, trash removed, ports cleared, map entry gone; no `.git/status drift`.

Migration:
13. Old worktrees (pre-v2) still work — flat-map fallback; add/open backfills keys.
14. Repo without `.workrex.lua` + `no_setup=true` behaves byte-identically to today.
15. README/AGENTS updated in sync; `chezmoi diff` matches intent only.

## 10. Moving-parts ledger (the c3 discipline, audited)

| Kind | Count | Items |
|---|---|---|
| New files | 0 | all code extends `dot_config/rex/worktrees.lua` |
| New shell scripts on disk | **0** | everything generated as `sh -c` strings |
| New state-file formats | **0** | git-config keys + existing files untouched |
| New API calls | 1 | `rex.call("session.new_window", …)` (+ `rex window ls` for dedup — trivial) |
| New user-facing actions | 3 | setup, merge(+apply), fix (setup_done internal) |
| New keybindings | 2 | `C-space>s`, `C-space>m` |

## 11. Explicitly deferred (with revisit triggers)

| Feature | Verdict | Trigger to revisit |
|---|---|---|
| Sandbox / remote / Conductor Cloud | out of scope | hosting needs appear |
| Dashboard / sidebar / statushooks | rejected in-scope | agent-status hunger surfaces; phase 4 of v1's plan |
| Conversation fork/continue (claude/codex) | out of scope | multi-worktree chats become the bottleneck |
| PR checkout, gh/glab | out of scope | `worktree_add pr=…` request |
| Archive/History restore list | deferred (v2 records trash-as-rescue) | remove-to-clear-picker need |
| Monorepo subdir configs / layouts DSL / `--foreach` | out of scope | a second monorepo identity appears |
| `workrex_sync` | trivial followup (same fileops helper) | first real need (node_modules re-link after root changes) |

## 12. Synthesis record (arena provenance)

- **Fact field**: c1 F1–F11 all verified by the cross-judge against the live CLI; `session.new_window` and `block_creator.list` additionally re-verified by the parent.
- **Base pick**: c1 (workmux-faithful) 55/60 — the only plan built entirely from
  verified API facts whose gate ("failure ⇒ no agent") is structural. Cross-judge
  concurred; incumbent (v1) scored worst (33.5) and contributed requirements only.
- **Grafts (by hand, not pasted)**:
  - c3 → server-side gate release (`workrex_setup_done`), marker-write-after-window
    invariant, `session.view` dedup, in-pane Enter-retry loop, "no config ⇒ today's
    behavior" gating decision, moving-parts ledger discipline.
  - c4 → pre-flight guards on remove (uncommitted, setup-running),
    abandoned-window detection, CLAUDE.local.md default symlink, `workrex_fix` verb.
  - c2 → per-step generated setup script with named failures (removes eval'd config
    passing entirely), streamed merge popup (no headless twin),
    hooks out of the action budget, repo-scoped trash naming.
  - c1 (base) → sandboxed config loader w/ `<global>` splice, git-config state
    machine + write-before-checkout, quarantine-then-prune cleanup, port counter +
    /dev/tcp probe, keybinding audit.
- **Convergence noted** (shipped as-is, no graft needed): Lua-committed
  `.workrex.lua`; `git config` base recording before checkout; no polling gate;
  self-session guard instead of a deferred-cleanup worker; workmux merge pipeline
  with merge/rebase/squash + abort paths; `.workrex/` gitignored via info/exclude.
- **Rejections** (the highest-signal part, per candidate's own rationale):
  - sentinel/polling gates (c2/c4's core) — a polling layer solves a problem the
    API surface already solved; wedges are nastier than the problem.
  - event-daemon gate via `rex.on` — event vocabulary unverifiable by CLI; second
    resident process with an unspecified lifecycle.
  - insert-staged-changes auto-commit on merge (c1/c2 copied from workmux) —
    turned down by c3 and kept out; committing user work silently is a behavior
    we don't own.
  - FNV-hash port allocation (c3) — collisions under 900 buckets for the realistic
    3–5 parallel worktrees were too likely; counter+probe is stateless beyond one
    git-config value.
  - detached setsid cleanup worker (workmux/c4 sketch) — existing self-session
    guard is already shipped and its failure is user-visible, one-step recoverable.
  - incumbent-phase-4 dashboard/status hooks — barred scope in this pass.
- **Fixes applied to the base during grafting**: `.env*` default unified to
  **copy** (c1's schema/§5.3 inconsistency per judge); trash dir named
  `<project>-<name>` (c2's collision bug per judge); setup marker written after
  window creation (judge flagged c1's `mark ok` pre-window order).
- **Verification result**: judge re-verified every load-bearing claim; parent
  re-verified both calls used in the synthesized gate (F7/F1); failure-mode walk
  through setup/merge/remove confirmed the catchers above. No unresolved wedge:
  every "this can still wedge" from candidate-4 reduced to a user-visible,
  one-command recovery in the synthesized design.
