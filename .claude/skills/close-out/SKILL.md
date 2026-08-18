---
name: close-out
description: Close out this project's work session. Use when the user says they are done working for now - "close out this session", "I'm ready to close out", "wrap up the session", "log the session", "prepare to end this session" - or asks to run the end-of-session routine. Walks the exact close-out checklist for the memory notebook, dashboard, and commit.
---

# Close out the session

Run the whole checklist now - don't just acknowledge. Do the safe local logging without
asking; ask first only before overwriting a hand-maintained doc, regenerating an artifact
(like a PDF), or anything outward-facing.

0. **Single-writer check FIRST, before writing anything.** If this project is a git repo,
   run `git log -1 --format=%h` and compare it to the HEAD this session started from. If it
   moved, another session has been working in this same folder: STOP, say so, and reconcile
   before touching a single file. This is step 0 and not step 8 on purpose - by step 8 five
   notebook files have already been rewritten, which is too late to find out.
1. **Journal it - on this session's OWN page.** Write one entry to
   `memory/daily/YYYY-MM-DD--<session-id>.md` (the session id was printed at session start;
   never invent one, and never write straight into `memory/daily.md` - that page is the
   merged journal and compaction owns it). Capture what we did, decisions, problems,
   blockers. Prefix what mattered most with **KEY**. Log failed approaches and why they
   failed - an unwritten dead end gets re-attempted next session.
2. **Log decisions - TWO writes each.** Every real decision from this session gets (a) its FULL
   dated entry (what + why) appended to the current month's `memory/decisions-archive-YYYY-MM.md`
   (create it and list it in `index.md` if new), and (b) a 2-3 line rule in `memory/decisions.md`
   under the right topic heading. If one overturns an older rule, REPLACE the rule in place and
   tag the archived entry: `- superseded YYYY-MM-DD`. If the writer lock blocks you because
   another session holds the notebook, do NOT drop the decision: park it on your own journal
   page as `DECISION: ...` and compaction promotes it. Same for steps 4 and 5.
3. **Trim `decisions.md` if it is over cap - REQUIRED, not optional, not deferrable.** If
   `memory/decisions.md` is over 250 lines at this point, that signals RULE BLOAT, not history
   (the archives already hold every full entry): delete rules that no longer govern anything,
   tighten wordy ones, regroup topics. A file still in the old diary format migrates to the
   rulebook now: full prose of every entry moves verbatim into dated archives, live rules stay
   as 2-3 liners grouped by topic. Delete nothing from the archives - the why is the product.
4. **Refresh `memory/CURRENT.md`.** Make it match reality: Status current, finished Now/Next
   items removed (with new next steps added), lapsed constraints deleted. Present-tense only -
   it is replaced, never appended.
5. **Sync open threads.** `memory/open-threads.md`: new issues/ideas/open questions added,
   fixed or answered ones removed (answered questions became decisions in step 2).
6. **Pages ridealong.** If any people-facing page in `pages/` was added, renamed, or retired
   this session, make `pages/pages.json` tell the truth in the same change.
7. **Regenerate and validate the dashboard.** Run `bash .claude/memory-dashboard-check.sh --write`
   to regenerate `project-status.html`'s panels straight from the notebook (roadmap is the one
   exception - it mirrors the plan by hand, so update it yourself if the plan moved), then run
   `bash .claude/memory-dashboard-check.sh` with no flag and fix whatever it refuses until it
   passes. Open the page once and eyeball it - it should read like a person wrote it.
8. **Commit - path-scoped.** If this project is a git repo, re-check the single-writer rule
   from step 0 one more time (HEAD may have moved while you worked), then commit **only the
   paths this session actually changed**, naming each one: `git commit memory/CURRENT.md
   memory/daily/<your page>.md project-status.html <other paths> -m "..."`. Never
   `git commit -a`, `git add -A`, `git add .` or `git add <directory>/` - another session's
   half-finished work may be sitting uncommitted in this same working tree, and every one of
   those sweeps it into your commit. The writer lock now **blocks** those commands outright
   when the tree holds changes this session did not write; if it blocks you, name your paths
   rather than working around it. (`git status` first: if you cannot say why a dirty file is
   dirty, it is not yours.) **"Not mine" expires - it is a reason to leave a file alone TODAY,
   never forever.** If a file was ALREADY dirty when this session opened, do not just note it
   and move on: open it, find out what it is, and resolve it one of three ways - **commit** it
   by name if it is finished work that never got committed; **trash** it if genuinely
   disposable, asking the user first; or **write it into `open-threads.md`** with what it is
   and why it is staying, so the next session inherits an explanation instead of a mystery.
   (Why: without an expiry, every session in turn reads the same unexplained files, correctly
   concludes "not mine", and leaves them - seven files once sat that way for eleven days, and
   they were finished work. A permanently dirty tree also destroys the signal this rule
   depends on: when `git status` is never empty, an alarming file cannot stand out. A file
   may be a mystery once, never twice.) Never push unless asked. If the compaction or size-cap
   nudges fired this session and were deferred, run them now before committing.
9. **Report - and read the record back.** Tell the user in a few lines what was logged and
   committed, and anything that still needs them. Include a short read-back of the FACTS that
   entered the notebook this session - each decision logged and each KEY line, quoted or
   tightly paraphrased - so a mis-remembered fact gets caught while it is one session old.
   Nothing verifies a recorded fact is TRUE except this moment: the notebook is trusted more,
   not less, as it ages. If the user corrects one, fix the page now, before the claim is
   released (a wrong decision gets its rulebook rule corrected and its archive entry the
   supersession tag - the archive is never rewritten).
10. **Release the notebook claim - naming yourself.**
    `bash .claude/memory-writer-lock.sh --release <your-session-id>` (the id the start hook
    printed, e.g. `--release 7ec0e085`). Naming yourself matters: if ANOTHER live session
    holds the claim, an unnamed release would drop THEIR claim and let a third session write
    over their in-flight work. If it answers `REFUSED`, the claim was never yours - leave it
    alone and close out anyway; nothing is wrong. Harmless if this session keeps working: the
    next notebook write simply re-claims it.
