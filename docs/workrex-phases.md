# Workrex phased plan

Workrex adds per-repo setup automation, file takeover, and a merge lifecycle to the Rex worktree sessions in `dot_config/rex/worktrees.lua`. The plan splits the v2 design (`docs/workrex.md`) into six phases. Each phase ends in a state you can check in a live Rex session. A phase is done only when its unit, live, and perf boxes are all checked. Phases run in order. P0 through P2 change nothing the user sees except new worktrees. P3 adds the setup window. P4 adds merge and remove. P5 adds recovery and docs.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a commit SHA. The body is a how-to. The appendices explain and record.

The program runs `pstack/skills/poteto-mode/playbooks/autonomous-run.md`, adapted for a dotfiles repository with no pull request workflow. The operator reviews each phase diff and lands it as one commit on `main`. There are no stacked branches and no PR ids.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [ ] State the protocol and this plan to the operator, then stop. Start execution only on the operator's explicit go.
- [ ] Read these at program start. Re-read them at every phase boundary.
  - [ ] `docs/workrex.md` (design of record)
  - [ ] `docs/research/workmux-core-notes.md` and `docs/research/conductor-notes.md`
  - [ ] `AGENTS.md` (Rex constraints)
  - [ ] `dot_config/rex/worktrees.lua`, `context.lua`, and `init.lua`
  - [ ] `pstack/skills/poteto-mode/playbooks/autonomous-run.md`
  - [ ] Run `git show origin/main:docs/workrex.md` and read it, so a stale local copy cannot drift from trunk.
- [ ] Skip the `/loop 1h` audit tick. Reason is one implementer session on a local repository, with the operator reviewing each phase before the next starts.
- [ ] Post a one-line status message to the operator at each phase boundary. Name the phase, the commit SHA, and any box left unchecked.
- [ ] On a hold order, stop at the end of the current box and leave the tree clean.

### Spawn owners

- [ ] Skip per-phase owners. Reason is the whole program is one file plus one test script, and splitting it across owners would create write conflicts on `worktrees.lua`.

### PR mechanics, for every phase

- [ ] Skip PR creation and rebases. Reason is the repository has no remote PR flow in use. Each phase is one commit on `main`.
- [ ] Run `chezmoi diff` before the commit and confirm it contains only the phase's files.
- [ ] Run `rex config check` and `rex config reload` after `chezmoi apply ~/.config/rex`.

### Verdict and merge, for every phase

- [ ] The operator reads the diff and the live evidence, then says go.
- [ ] Commit only after every box in the phase is checked.

### Boot recipe, for every live lane

Every lane runs against a scratch repository, not against a real project. The test script rebuilds it at `/private/var/folders/wb/xrqy4t111gs50qzgzxd_0by80000gn/T/opencode/workrex-proto/repo`.

- [ ] Reset the scratch repository with `tests/workrex-smoke.sh reset`.
- [ ] Drive the lane through `rex do` and `rex window ls --json`. Capture the terminal with `rex capture -s <label> -w <window>`.
- [ ] Save the terminal capture to `/tmp/workrex-<phase>/lane-<n>.txt` and the screen to `/tmp/workrex-<phase>/lane-<n>.png` with `screencapture -x`.
- [ ] Kill every scratch session at the end of the lane with `rex kill <label>`.

## Build the smoke test script (P0)

**Depends on.** None.

**Files.**

- [ ] Create `tests/workrex-smoke.sh`. Chezmoi does not deploy it because it has no `dot_` prefix.
- [ ] Create `tests/fixtures/repo/.workrex.lua` and `tests/fixtures/repo/.gitignore`.

**Build.**

- [ ] Write `reset` to build the scratch repository, commit a `.gitignore` with `.env*` and `node_modules`, and write `.env` and `.env.local`.
- [ ] Write the helpers `add`, `open`, `remove`, `assert_window`, `assert_config`, and `assert_file`. Every helper prints `PASS <name>` or `FAIL <name> <detail>` and sets a nonzero exit on failure.
- [ ] Write `all` to run every lane that exists at the current commit. A missing lane prints `SKIP <lane> not implemented yet`.
- [ ] Clean up every session the script creates, including after a failure.

**You see.**

- [ ] `./tests/workrex-smoke.sh all` prints one line per assertion and exits 0 on the current `main`.
- [ ] A forced failure, `WORKREX_SMOKE_FAIL=1 ./tests/workrex-smoke.sh all`, prints `FAIL` and exits 1.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] The script's own assertions fail on a wrong fixture. Change `.env` to a tracked file in `reset` and confirm `assert_file` reports `FAIL`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `the implementer model` at the PR head, run by the script on this machine.

- [ ] Lane 1. Regression lane against trunk. Run `add`, `open`, and `remove` at trunk. The current code passes. Save `lane-1.png`. Pass when all three exit 0.
- [ ] Lane 2. Duplicate add. Add the same name twice. Save `lane-2.png`. Pass when the second call prints the existing "already exists" message.
- [ ] Lane 3. Remove keeps the branch. Remove a merged worktree. Save `lane-3.png`. Pass when `git worktree list` drops the path and `git branch` keeps the branch.
- [ ] Lane 4. Session cleanup. Run the full script. Save `lane-4.png`. Pass when `rex ls` has no `proto/` label.
- [ ] Lane 5. Exit code on failure. Run with `WORKREX_SMOKE_FAIL=1`. Save `lane-5.png`. Pass when the exit code is 1 and the `FAIL` line names the assertion.
- [ ] Lane 6. Missing lane skip. Run `all` before P3 exists. Save `lane-6.png`. Pass when the setup lane prints `SKIP`.
- [ ] Lane 7. Reset idempotence. Run `reset` twice. Save `lane-7.png`. Pass when the second run exits 0 and the fixture files are unchanged.
- [ ] Lane 8. Dirty scratch repository. Leave an untracked file, then run `reset`. Save `lane-8.png`. Pass when `reset` clears it and still exits 0.
- [ ] Lane 9. Path with a space. Reset into a directory named `workrex proto`. Save `lane-9.png`. Pass when add and remove succeed.
- [ ] Lane 10. Branch prefix. Assert the created branch starts with `wm/`. Save `lane-10.png`. Pass when the branch name matches.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Total runtime of `./tests/workrex-smoke.sh all` and the wall time of one `rex do worktree_add`.
- [ ] Probe. Run `time ./tests/workrex-smoke.sh all` three times at trunk and three at head, interleaved.
- [ ] Baseline. Record the trunk runtime first.
- [ ] Rule. Head adds at most 20 s to the script runtime. One `worktree_add` stays under 10 s. The action budget is 30 s.

**Review gate.** None. P0 changes no interaction.

**Merge.**

- [ ] Commit `tests/workrex-smoke.sh` and the fixtures.

## Add config, state, environment, and ports (P1)

**Depends on.** P0.

**Files.**

- [ ] Edit `dot_config/rex/worktrees.lua`. All new code lives in this file. The file already holds the helpers the new code calls.
- [ ] Edit `README.md` and `AGENTS.md` with the config file name and the new state keys.

**Build.**

- [ ] Add `load_repo_config(root)`. Use `loadstring` and `setfenv` because Rex runs Lua 5.1 (Appendix A). Give the chunk a table with only `string`, `table`, `math`, `pairs`, `ipairs`, `tostring`, and `tonumber`. Require a table return. Validate `base`, `files.copy`, `files.symlink`, `post_create`, `setup`, `pre_merge`, `pre_remove`, `env`, and `port_block`. Abort on an unknown key, a non-string list entry, or a bad strategy.
- [ ] Add `git_config(root, key, value)`, `git_config_get(root, key)`, and `git_config_section_remove(root, section)`. Quote subsections that contain dots, as in `workrex.worktree."<name>".setup`, because `valid_name` allows dots (Appendix A).
- [ ] Add `set_base(root, branch, base)` and `get_base(root, branch)`. Write `branch.<branch>.workrex-base` before `git worktree add`.
- [ ] Add `write_env(root, name, path, branch, base, port)` and write `<path>/.workrex/env`.
- [ ] Add `ensure_exclude(root, path)`. Append `.workrex/` to `.git/info/exclude` once. Return whether this run added the line so rollback can remove it.
- [ ] Add `allocate_ports(root, name, size)`. Read `workrex.ports.next`, probe the block in one `bash -c` process using `/dev/tcp`, advance the counter, and store `workrex.worktree."<name>".ports`.
- [ ] Wire P1 into `worktree_add` after `git worktree add` and before `session.create`. Set the `base`, `created`, `agent`, and `session-id` keys.
- [ ] Extend the rollback block to kill a created session, remove the exclude line when this run added it, and unset both base keys. The port counter stays advanced on purpose, and a comment says so.
- [ ] Extend the duplicate check to fail early when the path is a registered worktree but has no session.

**You see.**

- [ ] A new worktree has `<path>/.workrex/env` with `WORKREX_*` values and a port block.
- [ ] `git config --local --get-regexp '^workrex\.'` lists the new keys.
- [ ] `.workrex/` does not appear in `git status`.
- [ ] `worktree_add` without `.workrex.lua` behaves as before, plus the env file.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add loader cases to the smoke script. A valid file loads, a syntax error aborts, a wrong return type aborts, and an unknown key aborts. Run `./tests/workrex-smoke.sh all`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `the implementer model` at the PR head, on the scratch repository.

- [ ] Lane 1. Regression lane against trunk. Run `add`, `open`, and `remove` at trunk and head. Save `lane-1.png`. Pass when head matches trunk for windows, labels, and branch naming.
- [ ] Lane 2. Env values. Save `lane-2.png`. Pass when `WORKREX_WORKSPACE_PATH`, `WORKREX_ROOT_PATH`, `WORKREX_WORKSPACE_NAME`, `WORKREX_BRANCH`, and `WORKREX_PORT` match the worktree.
- [ ] Lane 3. Ports. Add two worktrees. Save `lane-3.png`. Pass when the blocks differ and `WORKREX_PORT + 9` is free.
- [ ] Lane 4. Port reuse after remove. Add, remove, and add again. Save `lane-4.png`. Pass when the new block does not reuse the removed block.
- [ ] Lane 5. Config syntax error. Save `lane-5.png`. Pass when the action aborts before `git worktree list` changes and no directory is created.
- [ ] Lane 6. Unknown config key. Save `lane-6.png`. Pass when the error names the key.
- [ ] Lane 7. Exclude idempotence. Add two worktrees. Save `lane-7.png`. Pass when `.git/info/exclude` contains one `.workrex/` line.
- [ ] Lane 8. Old worktree. Open a worktree created before P1. Save `lane-8.png`. Pass when it opens and gains the keys.
- [ ] Lane 9. Rollback kills the session. Force `session.create` to fail with a bad label. Save `lane-9.png`. Pass when no session exists and the worktree is gone.
- [ ] Lane 10. Rollback removes the exclude line. Force the same failure on a repository without the line. Save `lane-10.png`. Pass when the line count is unchanged.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of `rex do worktree_add name=p1-<n>` and the loader time.
- [ ] Probe. Run `time rex do worktree_add ...` three times at trunk and three at head, interleaved.
- [ ] Baseline. Record the trunk median first.
- [ ] Rule. Head stays within 2 s of trunk and under 10 s. The loader stays under 100 ms.

**Review gate.** None. P1 adds files and config keys that the user does not interact with.

**Merge.**

- [ ] Run `chezmoi apply ~/.config/rex`, `rex config check`, and `rex config reload`, then commit.

## Take over gitignored files (P2)

**Depends on.** P1.

**Files.**

- [ ] Edit `dot_config/rex/worktrees.lua`.
- [ ] Edit `README.md` with the `files` schema.

**Build.**

- [ ] Add `list_ignored(root)` using one `git ls-files --others --ignored --exclude-standard` call with a 10 s timeout.
- [ ] Add `match_glob(pattern, path)` for `*`, `?`, and `**`. Anchor it at the repository root.
- [ ] Add `apply_file_rules(root, path, cfg, log)`. Copy matching files with `cp -pR`. Link matching entries with a relative target computed from the sibling layout. Skip a destination that exists and report it. Skip tracked paths. Stop with a warning above 200 matches.
- [ ] Default to `copy = { ".env*" }` when `files` is absent. Add the `CLAUDE.local.md` symlink when the file exists and is ignored.
- [ ] Run the rules from `worktree_add` in one `sh -c` batch with an 8 s timeout. On failure, run the P1 rollback.

**You see.**

- [ ] A fresh worktree has a copy of `.env` and `.env.local` from the main checkout.
- [ ] A `files.symlink` entry such as `node_modules` produces a relative link that resolves from a nested directory.
- [ ] Tracked files are never copied.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add glob cases to the smoke script. Pass when `**/*.env` matches nested files and `..` patterns are rejected.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `the implementer model` at the PR head.

- [ ] Lane 1. Regression lane against trunk. Add and open at trunk and head. Save `lane-1.png`. Pass when the window layout and session label are unchanged.
- [ ] Lane 2. Copy. Save `lane-2.png`. Pass when `.env` content matches the main checkout and the file is not tracked.
- [ ] Lane 3. Symlink. Save `lane-3.png`. Pass when `readlink` returns a relative path.
- [ ] Lane 4. Nested read. Save `lane-4.png`. Pass when reading the linked file from `<path>/web/` works.
- [ ] Lane 5. Existing destination. Save `lane-5.png`. Pass when a file created by setup is not overwritten.
- [ ] Lane 6. Tracked file. Save `lane-6.png`. Pass when a tracked `config.json` is not copied.
- [ ] Lane 7. Match cap. Create 250 ignored files. Save `lane-7.png`. Pass when the run warns and copies 200.
- [ ] Lane 8. Escape pattern. Save `lane-8.png`. Pass when a pattern with `..` aborts with a clear error.
- [ ] Lane 9. CLAUDE.local.md. Save `lane-9.png`. Pass when the ignored file appears as a symlink.
- [ ] Lane 10. Idempotence. Run add twice on the same name after removing the session. Save `lane-10.png`. Pass when the second run reports existing destinations and changes no file.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of the file step inside `worktree_add`.
- [ ] Probe. Time an add with 1 file and an add with 100 ignored files.
- [ ] Baseline. Record the 1 file time first.
- [ ] Rule. The file step stays under 3 s for 100 files and the whole add stays under 10 s.

**Review gate.** None. P2 changes files on disk, not the interaction.

**Merge.**

- [ ] Apply, reload, commit.

## Gate the agent on setup (P3)

**Depends on.** P2.

**Files.**

- [ ] Edit `dot_config/rex/worktrees.lua`.
- [ ] Edit `README.md` and `AGENTS.md` with the `setup` schema, the new action, and the `C-space>s` key.

**Build.**

- [ ] Add `build_setup_script(cfg, ctx)`. Emit one concrete script. Each step prints its command, runs `sh -c` with the output visible, and reports the failing step and exit code. Wrap the steps in a retry loop with an explicit `ok` flag. On success, call `rex do -s "$REX_SESSION" workrex_setup_done name=<quoted> agent=<quoted>`, then `exec "$SHELL" -l`. On abandon, exit 1.
- [ ] Change `worktree_add` to create the session with two windows, `setup` and `nvim`, and no agent window when `setup` or `post_create` is non-empty. Set `workrex.worktree."<name>".setup` to `running` first.
- [ ] Add the `workrex_setup_done` action. Resolve the worktree by name, list the session's windows with `rex window ls -s <label> --json`, close a stale agent window when the agent changed, add the agent window with `session.new_window`, then write `setup = ok` last. On a window failure, write `failed` and return the error.
- [ ] Add the `workrex_setup` action and bind it to `C-space>s`. It regenerates the script, opens a fresh setup window, and sets `running`.
- [ ] Change `worktree_open` to open a setup-pending session when the state is not `ok` and no agent window exists.
- [ ] Add abandoned detection. When the state is `running` and the session has no setup window, report it and offer `C-space>s`.
- [ ] Update `worktree_add_prompt` to print "setup running, the agent opens when it finishes" instead of "ok".
- [ ] Keep `no_setup=true` as the escape hatch that restores the old two-window session.

**You see.**

- [ ] `C-space>w` creates a session with a setup window that streams the install, then an agent window appears.
- [ ] A failing setup shows the failing step, keeps the window open, and never opens the agent.
- [ ] Enter retries in the same window. `C-space>s` opens a fresh setup window.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add script-builder cases. Pass when quoting a command with spaces or single quotes produces a script that `sh -n` accepts.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `the implementer model` at the PR head, the interaction change in this plan.

- [ ] Lane 1. Regression lane against trunk. Add without `.workrex.lua`. Save `lane-1.png`. Pass when the session has nvim and the agent immediately, as at trunk.
- [ ] Lane 2. Happy setup. Save `lane-2.png`. Pass when the setup window streams, the agent window appears after success, and `setup = ok`.
- [ ] Lane 3. Failing setup. Save `lane-3.png`. Pass when the failing step is named, no agent window exists, and the state is `failed`.
- [ ] Lane 4. Retry in place. Press Enter after fixing the command. Save `lane-4.png`. Pass when the agent window appears and the state is `ok`.
- [ ] Lane 5. Abandon. Press Ctrl-D. Save `lane-5.png`. Pass when the state stays `failed` and no agent window exists.
- [ ] Lane 6. Closed setup window. Close the window mid-install. Save `lane-6.png`. Pass when `worktree_open` reports the abandoned state.
- [ ] Lane 7. Double report. Call `workrex_setup_done` twice. Save `lane-7.png`. Pass when the second call adds no window.
- [ ] Lane 8. Agent change. Rerun with a different agent. Save `lane-8.png`. Pass when the old agent window is gone and one new agent window exists.
- [ ] Lane 9. Env in the agent. Save `lane-9.png`. Pass when `env | grep WORKREX` in the agent window lists every variable.
- [ ] Lane 10. Escape hatch. Run with `no_setup=true`. Save `lane-10.png`. Pass when no setup window appears and the agent opens.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Time from `rex do worktree_add` returning to the agent window existing, and the action wall time.
- [ ] Probe. Run a 30 s setup command three times. Record the action time and the time to the agent window.
- [ ] Baseline. Record the trunk add time first.
- [ ] Rule. The action returns under 10 s while setup runs. Time to the agent window is setup time plus under 3 s. The action stays under 30 s.

**Review gate.** The operator reviews before merge.

- [ ] Copy the lane 2 screenshot into `docs/media/p3-setup-ok.png` and the lane 3 screenshot into `docs/media/p3-setup-fail.png`.
- [ ] Record a 30 to 60 second video of the setup gate with `screencapture -v`. Save it as `docs/media/p3-gate.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready and wait for the operator.

**Merge.**

- [ ] Apply, reload, commit after the operator's go.

## Merge and remove with guards (P4)

**Depends on.** P3.

**Files.**

- [ ] Edit `dot_config/rex/worktrees.lua`.
- [ ] Edit `README.md` and `AGENTS.md` with the merge action and the `C-space>m` key.

**Build.**

- [ ] Add `worktree_merge`. Resolve the source by name or from the current session. Refuse the main worktree. Refuse the source session. Resolve the target from `into`, then the recorded base, then the detected default branch.
- [ ] Add the guards. Refuse when the source has uncommitted changes unless `allow_dirty=true`. Refuse when the target worktree has tracked changes. Refuse when the branch equals the target. Refuse when `setup` is `running`.
- [ ] Run the merge pipeline in `context.popup`. Run `pre_merge` hooks in the source worktree with `WORKREX_*` env. Support `merge`, `rebase`, and `squash`, each with its abort path. Stream the output and keep failures on screen.
- [ ] Run cleanup in the same popup after a successful merge. Kill the session with `rex_bin()`, remove the worktree with the quarantine path, keep the branch when `git branch -d` refuses, and forget the session.
- [ ] Extend `worktree_remove`. Refuse when the worktree has uncommitted changes unless `force=true`. Refuse when setup is `running` unless `force=true`. Run `pre_remove` hooks with a 25 s cap. Quarantine the directory, prune, and remove the trash in the background with `nohup rm -rf`.
- [ ] Add `worktree_merge_prompt` and bind `C-space>m`.
- [ ] Update `worktree_remove_prompt` to pass `force=true` only after the user confirms.

**You see.**

- [ ] `C-space>m` streams the guards, the hooks, the merge, and the cleanup, then the worktree is gone and the branch is kept.
- [ ] A conflict aborts and leaves the target clean.
- [ ] A dirty source refuses with a message that names `allow_dirty`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add target-resolution cases. Pass when `into` wins, the recorded base is second, and the detected default is last.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `the implementer model` at the PR head.

- [ ] Lane 1. Regression lane against trunk. Remove a merged worktree at trunk and head. Save `lane-1.png`. Pass when both delete the worktree and keep the branch.
- [ ] Lane 2. Merge happy path. Save `lane-2.png`. Pass when the branch lands, the session is gone, and the worktree path no longer exists.
- [ ] Lane 3. Merge conflict. Save `lane-3.png`. Pass when the merge aborts, the target is clean, and the branch survives.
- [ ] Lane 4. Rebase conflict. Save `lane-4.png`. Pass when the rebase aborts and the message names the source path.
- [ ] Lane 5. Squash. Save `lane-5.png`. Pass when the target has one new commit and the branch is kept.
- [ ] Lane 6. Dirty source. Save `lane-6.png`. Pass when the merge refuses and `allow_dirty=true` proceeds.
- [ ] Lane 7. Setup running. Save `lane-7.png`. Pass when the merge refuses with the setup message.
- [ ] Lane 8. Remove dirty. Save `lane-8.png`. Pass when remove refuses without `force`.
- [ ] Lane 9. Unmerged branch. Save `lane-9.png`. Pass when the branch survives and the trash path is reported.
- [ ] Lane 10. Self session. Save `lane-10.png`. Pass when merge and remove from the source session refuse with the switch-away message.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Action wall time for `worktree_merge` and `worktree_remove`.
- [ ] Probe. Time three merges and three removes. Measure the popup close time separately.
- [ ] Baseline. Record the trunk remove time first.
- [ ] Rule. Both actions return under 5 s. Remove returns before the background `rm -rf` finishes.

**Review gate.** The operator reviews before merge.

- [ ] Copy the lane 2 screenshot into `docs/media/p4-merge-ok.png` and the lane 3 screenshot into `docs/media/p4-merge-conflict.png`.
- [ ] Record a 30 to 60 second video of a merge and a remove with `screencapture -v`. Save it as `docs/media/p4-merge-remove.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready and wait for the operator.

**Merge.**

- [ ] Apply, reload, commit after the operator's go.

## Add recovery and finish the docs (P5)

**Depends on.** P4.

**Files.**

- [ ] Edit `dot_config/rex/worktrees.lua`.
- [ ] Edit `README.md` and `AGENTS.md`.
- [ ] Edit `tests/workrex-smoke.sh`.

**Build.**

- [ ] Add `workrex_fix`. Diagnose the three states, `running` with no setup window, `ok` with no agent window, and a stale session map entry. Heal each by opening the right window and fixing the map.
- [ ] Update the pickers to show the setup state per worktree.
- [ ] Update the README keymap table and the AGENTS Rex section, including the layout tree and the Common Tasks table.
- [ ] Extend the smoke script to run every lane from P1 through P4 in one pass.

**You see.**

- [ ] `rex do workrex_fix name=<n>` prints a diagnosis and heals the state.
- [ ] The README and AGENTS entries match the code.
- [ ] `./tests/workrex-smoke.sh all` passes every lane.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add fix cases. Pass when each of the three states heals and prints the action it took.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `the implementer model` at the PR head.

- [ ] Lane 1. Regression lane against trunk. Run the full smoke script at trunk and head. Save `lane-1.png`. Pass when trunk passes the P0 lanes, skips the rest, and head passes all lanes.
- [ ] Lane 2. Heal `running` with no setup window. Save `lane-2.png`. Pass when a setup window opens.
- [ ] Lane 3. Heal `ok` with no agent window. Save `lane-3.png`. Pass when the agent window appears.
- [ ] Lane 4. Heal a stale map entry. Save `lane-4.png`. Pass when `worktree_open` finds the live session again.
- [ ] Lane 5. Fix idempotence. Run the fix twice. Save `lane-5.png`. Pass when the second run reports no change.
- [ ] Lane 6. Picker state. Save `lane-6.png`. Pass when the picker shows `ok`, `failed`, or `running` next to each worktree.
- [ ] Lane 7. README keymap. Save `lane-7.png`. Pass when the table lists `w`, `s`, `o`, `m`, and `W`.
- [ ] Lane 8. AGENTS layout. Save `lane-8.png`. Pass when the layout tree and the Common Tasks table name the new verbs.
- [ ] Lane 9. Config check. Run `rex config check` after every phase file is applied. Save `lane-9.png`. Pass when it exits 0.
- [ ] Lane 10. Clean tree. Run `chezmoi diff` after the final apply. Save `lane-10.png`. Pass when it reports no unexpected drift.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Full smoke script runtime.
- [ ] Probe. Time three full runs at head and three at trunk.
- [ ] Baseline. Record the trunk runtime first.
- [ ] Rule. Head runtime stays under 3 minutes. No single lane exceeds 30 s except the setup lane.

**Review gate.** The operator reviews before merge.

- [ ] Copy the lane 2, lane 3, and lane 4 screenshots into `docs/media/p5-fix-states.png`.
- [ ] Record a 30 to 60 second video of the three heals with `screencapture -v`. Save it as `docs/media/p5-fix.mp4`.
- [ ] Post the screenshots, the video, and the docs diff in chat. Wait for the operator.

**Merge.**

- [ ] Apply, reload, commit after the operator's go.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with the phase commits, the smoke output, and the remaining risks from Appendix C.
- [ ] Update `docs/workrex.md` if any phase changed a decision.

## Appendix A. Prototype evidence

Measured on this machine on 2026-10-31. The prototype session was killed after the run.

- **Rex runs Lua 5.1.** `rex do -e 'return _VERSION'` printed `Lua 5.1`. `type(loadstring)` and `type(setfenv)` both return `function`. The v2 plan's `load(source, name, "t", env)` sandbox cannot work. P1 uses `loadstring` plus `setfenv`.
- **Panes export `REX_SESSION`, `REX_BLOCK`, `REX_BIN_DIR`, and `REX_SERVER`.** Captured from a setup pane with `env | grep -E '^REX_'`. The setup script reads `$REX_SESSION` for its self-report, so no session id has to exist when the script is generated.
- **`session.new_window` requires the caller's control stream to be attached to the target session.** Calling it unscoped from `rex do` failed with `409 conflict, stream is not attached to session`. Calling it inside `rex do -s proto/workrex` succeeded and the window appeared. The `workrex_setup_done` action runs scoped, like the pickers.
- **`session.create` with one setup window works.** `rex window ls -s proto/workrex` showed one `setup` window. The window label passed in `initial_windows` is honored.
- **`exit.on_completion = false` keeps the pane open after the script exits.** The captured pane showed the script output followed by the login shell prompt. The setup output stays readable.
- **Git config subsections with dots need quoting.** `git config 'workrex.worktree."foo.bar".setup' ok` round-trips through `--get-regexp`. The unquoted form returns nothing. `--remove-section 'workrex.worktree."foo.bar"'` removes it.
- **`rex window ls -s <label> --json` returns the session id, label, and windows.** It is the dedup probe for `workrex_setup_done`.

## Appendix B. Alternatives rejected

- **A separate `workrex.lua` module.** The v2 claim that `worktrees.lua` helpers are reusable is false because they are file-local. Splitting the module would require exporting ten helpers or duplicating them. The design keeps one file and accepts its size.
- **A global `~/.config/rex/workrex.lua` config layer.** It collides with a module of the same name and no second repository needs shared hooks yet. Add it when that need appears.
- **The claim that the trash directory is the rescue location.** `git worktree prune` removes the admin entry, so the renamed directory is no longer a usable worktree. The rescue is the kept branch, and the plan says so.
- **The cross-session foreign-pane scan.** It costs one probe per pane in every session and protects against a rare case. The setup state guard and the self-session guard cover the common losses.
- **A scriptable `worktree_merge_apply` twin.** It doubles the merge code for a need nobody has expressed. The popup path is the only one shipped.
- **Sentinel polling and event daemons.** The arena rejected both. Rex can add the agent window after setup, so no process has to wait.
- **Copying staged changes into a merge commit automatically.** The user commits their own work. The merge refuses instead.

## Appendix C. Risks

- **The user closes the setup window mid-install.** The state stays `running` and no agent opens. P3 detects the abandoned window on the next open and P5 adds the heal. Watch this in Lane 6 of P3.
- **A huge repository pushes `git worktree add` past the 30 s action budget.** The plan caps the add at 20 s and reports the git error. Moving the add into a pane is the follow-up if it happens in practice.
- **The port probe misses a squatter that binds after the probe.** The counter only advances, so a collision needs two worktrees to reuse a block. Watch for it in Lane 4 of P1.
- **Docs drift.** README and AGENTS change in the same commit as the code in every phase. P5 checks the final state.
- **A repository config that is hostile.** The loader gives the chunk no `io`, `os`, or `require`. It still runs arbitrary string and table code, which is the same trust level as a shell hook in the same file.

## Appendix D. Links and reading list

- `docs/workrex.md` is the design of record.
- `docs/research/workmux-core-notes.md` and `docs/research/conductor-notes.md` hold the upstream behaviour.
- `docs/research/arena/JUDGE.md` records the design review that produced v2.
- `rex api describe session.new_window` and `rex api call block_creator.list` are the API checks to re-run when Rex updates.
- `AGENTS.md` holds the repository conventions for editing, applying, and reloading the Rex config.
