# Workrex Arena — progressive todolist

- [ ] A. Frame: artifact = competing workrex implementation specs; rubric fixed (6 criteria); 4 candidates + incumbent (`docs/workrex.md`) enter the ring; output paths assigned
- [x] A. Frame: rubric (6 criteria) fixed; runners = 4 candidate subagents + incumbent doc; output paths `/tmp/opencode/arena-workrex/candidate-{1..4}/`
- [x] B. Fan out: 4 candidates completed (0 dropouts), each with plan.md + rationale.md
- [x] C. Cross-judge: readonly judge scored all 5 blind; crowned c1 (55/60), runner-up c3/c4 (52.5); verdict in arena-workrex/JUDGE.md
- [x] D. Pick: parent read every candidate end-to-end; scores agreed with judge; base = candidate-1; convergence recorded
- [x] E. Graft: c3 (server-side release, marker-last, dedup, in-pane retry), c4 (remove guards, fix verb), c2 (per-step script, streamed merge popup + apply twin, trash naming); rejections logged in docs/workrex.md §12
- [x] F. Verify: parent re-verified F1/F7 against live CLI; consistency scan (stray CJK, naming, unfinished sentences — all fixed); failure-mode walk found no unresolved wedge
