# Workrex design arena — JUDGE verdict (2026-10-31)

All five plans were read in full. Every load-bearing rex API claim was re-verified
read-only against the live CLI (`rex --help`, `rex window new --help`, `rex api describe
session.create / session.new_window / session.view`, `rex api call block_creator.list`,
`rex wait --help`, `rex run --help`, `rex do --help`, `rex block --help`, `rex config --help`)
and against the actual sources (`dot_config/rex/worktrees.lua`, `context.lua`), plus
platform checks (`flock`/`setsid` absent, `/bin/sh` = bash 3.2, nc/lsof present).

## 1. Rubric scores

| Criterion | c1 | c2 | c3 | c4 | c5 (incumbent) |
|---|---|---|---|---|---|
| 1. Rex-constraint correctness | **10** | 9 | 9 | 8.5 | 6.5 |
| 2. Setup gating soundness | **9.5** | 8 | 9 | 9 | 5 |
| 3. State & config integrity | **9** | 8 | 8 | 9 | 6.5 |
| 4. Merge/cleanup safety | 8.5 | 8 | **8.5** | 8.5 | 6 |
| 5. Scope discipline | 8 | 7 | **9** | 8 | 5 |
| 6. Verifiability | **10** | 9 | 9 | 9.5 | 4.5 |
| **Total** | **55** | 49 | 52.5 | 52.5 | 33.5 |

### Per-criterion justification (short form)

1. **Rex-constraint correctness** — c1: 11 explicit verified facts (F1–F11), each of which I
   independently confirmed (window.new -s, session.create nullable initial_windows, block
   options `additionalProperties:false` with no env, exit.on_completion semantics, rex wait,
   no flock/setsid, blocks-on-login-PATH vs action-PATH, session/kill quirks). Nothing
   imagined. c2/c3: correct budget math and PATH handling; c3 verified `session.new_window`
   directly, the single load-bearing call. c4: verified `initial_input` + `terminal.write`
   + mkdir lock; minor reliance on session.view probed from shell gate scripts (fine). c5:
   mostly correct on already-proven patterns but plans explicitly unverified items
   ("worth checking REX API support") and proposes self-installing `~/.local/bin` helpers.
2. **Setup gating soundness** — c1: no sentinel at all; the setup process itself creates the
   agent window after success (`fail` exits *before* the window-new call → structurally
   guarantees "failure ⇒ no agent"), git-config state machine (`running→ok|failed`)
   makes any wedge diagnosable with one `git config`, rerunnable. Weak point (acknowledged):
   closing the setup window mid-orphan leaves `running` until manual rerun. c4: deepest
   failure-path analysis (three independent catchers + hard timeout), with the wedge
   risk (initial_input typing race) honestly named plus a `workrex_fix` recovery verb.
   c3: callback + window-label dedup, marker written last, in-pane Enter-retry — clean,
   recoverable. c2: workable poll loop but a closed setup window can silently wait up to
   30 min before the hint appears. c5: no failure-mode analysis at all.
3. **State & config integrity** — c1 & c4 best: c1 four-layer config precedence with
   sandboxed (no-`_ENV`) project config + git-config primary with lazy backfill keeping
   the flat session file as read fallback; c4 worktree-local canonical state that dies
   with the worktree (no registry drift) + git-config base fallback + mkdir lock with
   stale-break. c2 has one real bug (see §4) plus deferred local-override layer.
   c3 minimal by design (`setup.done` dies with the worktree — zero GC), no overlay layers
   (deferred explicitly). c5 loose names (`workrex-sessions` cites "unchanged" but the
   existing file is `worktree-sessions`) and no locking story.
4. **Merge/cleanup safety** — c1 quarantine-rename-then-prune with trash retained as rescue
   when `branch -d` refuses; cleanup failure ≠ merge failure. c3 most conservative on
   uncommitted work (refuses staged auto-commit that c1/c2 copy from workmux) but keeps
   plain `git worktree remove` (drops the EBUSY rationale quarantine solves). c4 adds
   foreign-pane enumeration + setup-running refusal with `force=1`. c5 high-level only.
5. **Scope discipline** — c3 is the minimal-surface champion (audited ledger: 1 new file,
   2 binds, byte-compatible no-config path). c1 adds only m/e keys (verified free) with a
   `no_setup` escape hatch. c2 grows 9 new actions/4 keys (audited but large). c5 plans a
   dashboard/status phase-4 the current task bars, and renames existing actions
   (`worktree_add`→`workrex_add`), breaking documented CLI verbs.
6. **Verifiability** — c1 and c4 produce ordered, expected-output checklists including
   their own failure paths; c1 additionally pins read-only schema probes to defend against
   future rex updates. c2/c3 strong. c5 verifies only phase 1.

## 2. Crowned winner: **candidate-1** (55/60)

Reasoning: it is the only plan built end-to-end from a fact table whose every entry I could
confirm against the live CLI, it eliminates the sentinel question entirely (the gate is
colocated with the setup process; failure ⇒ no agent is structural, not negotiated between
two processes), it converts the incumbent's flat session file into git-config state with a
safe migration window, and its verification checklist is the most complete — including
schema pins guarding against future rex drift. Deductions are small and documented:
staged-change auto-commit on merge (a workmux behavior c3 rightly refuses), default `.env*`
takeover also applied to config-less repos, and minor argv-numbering consistency in §8.1.

**Runner-up: candidate-3 (52.5/60)** — wins on scope discipline and refused the staged
auto-commit; essentially tied with candidate-4 (52.5), which wins on gate depth
(three-catcher journal + `workrex_fix` wedge-buster) but is slightly larger and leans more
on shell-side session.view probing.

## 3. Top-2 ideas worth grafting per candidate

- **c1**: (1) git-config setup state machine (`running→ok|failed`) consumed by
  merge/remove so a wedged setup blocks merge with a precise error; (2)
  quarantine-rename-then-prune teardown, keeping the trash dir as the named rescue
  location when `branch -d` refuses unmerged work.
- **c2**: (1) streamed merge pipeline in a popup + a machine-readable `worktree_merge_apply`
  headless twin (visibility for hooks, scriptability preserved); (2) deterministic gating
  decision (setup needed iff actual copy/symlink matches exist) so config-less repos keep
  today's instant behavior — plus per-entry port sizes with GC-on-read.
- **c3**: (1) `workrex_setup_done` self-report callback + `session.view` window-label dedup
  (no polling, no daemon, idempotent double-report guard); (2) in-pane retry loop (Enter
  re-runs setup, Ctrl-D abandons) — self-healing with zero new actions; also adopt its
  audited "moving-parts ledger" discipline as a spec practice.
- **c4**: (1) sentinel-ownership table with three independent catchers + hard timeout
  backstop in a journal-based gate; (2) `workrex_fix` recovery verb that re-types the gate
  via verified `terminal.write` — the honest wedge-buster; also its lstat-class symlink
  idempotency rules.
- **c5**: (1) the Conductor/workmux→workrex requirement digest table (env var set, 10-port
  block framing, Conductor "config is project config" lesson) — the best requirements
  statement of the five; (2) shippable-phase decomposition for rollout.

## 4. API-claim adjudication (leveraged evidence: live CLI + sources)

| Claim | Adjudication | Evidence |
|---|---|---|
| (c1) `rex window new -s SESSION [LABEL] [-c DIR] [--focus=false] [-- COMMAND...]` adds a window to a running session | **verified-true** | `rex window new --help` shows exactly these flags; `rex window close/ls/inspect` exist |
| (c1) `exit.on_completion=false` (and quick-fail-stays-open) in terminal block options | **verified-true** | `block_creator.list` schema: `exit.on_completion` (default true, threshold 250 ms — "a quick failure leaves it open either way") |
| (c1) env file sourceable by generated wrapper commands (no per-block env) | **verified-true (sound)** | schema `additionalProperties:false`; option list is `shell, command, args(deprecated), login, cwd, path_prepend, size, theme, initial_input, exit` — no `env` |
| (c1) F2: `session.create` accepts `initial_windows: null` / single-window array | **verified-true** | `rex api describe session.create`: type `["null","array"]`; "If any of them fails, the server creates no session" |
| (c1) F4/F7: `rex wait` returns terminal child's exit status, bounded by `--for` | **verified-true** | `rex wait --help` matches verbatim |
| (c1) F6: terminal blocks run commands through the login shell's PATH; only `rex.exec` in actions is constrained | **verified-true** | `command` option description + AGENTS.md gotcha |
| (c1) F10: macOS lacks standalone `flock`/`setsid`; `/bin/sh` is bash 3.2 | **verified-true** | `which flock`, `which setsid` → not found; `bash 3.2.57` |
| (c2) gate polling of per-worktree `status` file; env wrapping via sourceable `.workrex/env` | **verified-true as a design** (no API risk; trivially implementable) | pure file mechanism; aligns with the no-env-option finding |
| (c2) `session.new_window` used by `worktree_setup` rerun | **verified-true** | schema confirmed |
| (c3) setup-pane-only session (`initial_windows` = one setup window) | **verified-true** | array of 1 + nullable type confirmed |
| (c3) `rex.call("session.new_window", …)` with required `session_id`, `layout`, optional `window_label`/`focus` | **verified-true** | `describe session.new_window` matches the quoted schema exactly (including required `session_id`) |
| (c3) "no env-injection flag" for `rex run` | **verified-true** | `rex run --help` flags: split/ratio/block/session/window/cwd/keep-open/shell/label/focus/json/wait |
| (c3) stateless FNV-hash port block | **design choice** — implementable trivially; correctness is design-level (collision-prone across repos; documented self-heal by user override) | n/a |
| (c4) `initial_input` terminal option ("text typed once its program starts") | **verified-true** | schema wording matches |
| (c4) `terminal.write` callable from actions (types into a live terminal) | **verified-true** | terminal flavor methods include `write { data }`; `context.lua:15` already uses the identical `rex.block.call(M.terminal, "pwd", …)` pattern |
| (c4) `.workrex/journal` with three concurrent failure sentinels | **design choice** — mechanism is plain file appends, sound logic | n/a |
| (c4) macOS `mkdir` lock for port leases | **verified-true as a primitive** (mkdir atomicity is POSIX; `flock` absent, confirmed) | n/a |

## 5. Factual errors found in the candidates

- **c2 (integrity bug)**: `workrex-archives/<name>.meta` is keyed by worktree *name* alone in
  the global state dir; two different repos can both have worktree `t1` → history/restore
  collides and can restore the wrong repo's meta. Needs `<project>/<name>` or a repo-scope
  prefix. Editorial leftovers too: §8.5 contains an unfinished self-contradicting sentence
  ("Bound as `worktree_archive_prompt`'s maint clarifier… no —`). Also §7.2's die() writes
  to `/dev/tty` fallback `|| printf '%s' ""` inside a popup script is dubious (popup is
  already a pane).
- **c2 (budget)**: worst-case action ~26 s of its own admission leaves ~4 s margin for
  session.create + remember_session; tight but documented.
- **c3 (editorial)**: stray Chinese word "当前" in §4's `workrex_setup_retry` row; §5.5 steps
  4/5 duplicate the stale-window removal description. `workrex_setup_done`'s §5.3 uses a
  `port` variable that is never derived inside that action (recoverable via the
  deterministic hash, but unspecified); the cfgfile argv numbering in c1 §8.1 (`$8`) is
  inconsistent with §4.2 (`$7`) — c1's editorial nit.
- **c1**: default `.env*` takeover makes it the symlink default when `files` is empty —
  wording in §2.2 calls the field `symlink = { ".env*" }` for files that are described as
  copied elsewhere in the text (copy-vs-symlink default is muddled between §2.2 and §5.3).
  Also its POSIX-sh `cfg_run` uses `local` and `eval "set -- ${arr[@]}"` — works in
  bash-3.2/dash sh, but the claim "no exotic quoting transported" coexists with `eval`-ing
  serialized config; it is correct as written (generated, not repo-authored) but worth
  noting.
- **c4**: gate's `has_setup_block` probes `session.view` from a shell every 2 s —
  plausible but heavier than stated (needs job-control-safe invocation); `kill -0 $pid`
  probing a foreign pane's pid works only while the shell is alive; all sound but leans on
  untested-by-me shell mechanics, unlike c1/c3 whose critical path is verified API.
- **c5 (incumbent)**: names the existing state file `workrex-sessions` while claiming it is
  "unchanged" from `worktree-sessions`; invents `os.pathstyle` helper; writes CLI syntax
  `rex do workrex_setup_done -s <session_id>` (real form is `rex do -s SESSION action`);
  proposes setup helpers self-installed into `~/.local/bin` at runtime (PATH/chezmoi-drift
  hazard); phase 4 plans dashboard + status hooks that the current task explicitly bars —
  judged against the rubric this is planned barred scope, and the doc verifies only Phase 1.
