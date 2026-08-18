#!/bin/bash
# PostToolUse (Bash) hook. v7. PORTABLE / self-locating.
# v7: the journal is memory/daily.md PLUS the per-session pages on the memory/daily/
# shelf, so both the "did the journal ride along in this commit?" check and the
# freshness grace window look at either. (A session that journalled onto its own shelf
# page and committed it used to get nudged as if it had logged nothing.)
# v6: dedupe state moved from the shared system temp dir to ~/.claude/tmp/ (private,
# survives temp cleaning, no predictable world-writable path on shared machines).
# After a successful `git commit` in this project's repo, if the notebook wasn't
# updated as part of it and hasn't been touched this session, inject a reminder
# to close out the milestone (journal + decisions + dashboard) and commit it.
# v5: the journal-freshness grace window now also requires REAL uncommitted edits
# to memory/daily.md - a bare touch (a checkout, a stray write) used to reset the
# clock and silence the nudge without any content having been logged.
# The hook only provides the deterministic trigger + freshness check; Claude
# decides whether the commit was milestone-worthy.
# v4: commit detection no longer parses git's output (a quiet `git commit -q`
# prints nothing, which silently defeated the v3 regex). Instead: if a commit
# COMMAND ran here, ask the repo itself whether a fresh commit just landed
# (HEAD changed since last check + HEAD is seconds old). State lives in the
# system temp dir, never inside the repo, so `git status` stays clean.
# Portable stat: BSD (macOS) -f, GNU (Linux) -c fallback.
input=$(cat)

PROJ="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DAILY="$PROJ/memory/daily.md"
[ -d "$PROJ/memory" ] || exit 0   # no memory system in this project -> stay silent
                                  # (dir, not daily.md: a deleted inbox must not
                                  # silence the commit nudge - 2026-08-04 audit)

# Raw prefilter before ANY interpreter spawns (2026-08-04 audit): python startup
# alone costs ~40ms, and this hook fires after EVERY Bash command. Only a command
# that can possibly be a git commit deserves a parse. Fail-safe by direction: JSON
# never escapes letters or spaces, so the literal "git commit" always survives
# encoding - the substring test can only OVER-fire, and the authoritative answer
# still comes from the parsed JSON below (same pattern as the writer lock's
# raw-glob prefilter).
case "$input" in
  *"git commit"*) : ;;
  *) exit 0 ;;
esac

# Parse the hook JSON once: (1) did a git commit COMMAND run? (2) which dir
# did it run in (leading 'cd X &&' wins, else the hook's cwd)? No jq dependency.
{ read -r is_commit; read -r commit_dir; } < <(printf '%s' "$input" | /usr/bin/python3 -c '
import sys, json, re
try: d = json.load(sys.stdin)
except Exception: print("0"); print(""); raise SystemExit
cmd = d.get("tool_input", {}).get("command", "") or ""
ok = "git commit" in cmd
m = re.match(r"\s*cd\s+(.+?)\s*&&", cmd)
where = m.group(1).strip().strip("\x27\"") if m else (d.get("cwd", "") or "")
print("1" if ok else "0")
print(where)
' 2>/dev/null)
[ "$is_commit" = "1" ] || exit 0

# Only act if the commit ran in THIS project's repo (not a nested/other repo).
if [ -n "$commit_dir" ]; then
  ctop=$(git -C "$commit_dir" rev-parse --show-toplevel 2>/dev/null)
  ptop=$(git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$ctop" ] && [ -n "$ptop" ] && [ "$ctop" != "$ptop" ]; then
    exit 0
  fi
fi

# Did a commit actually land? Ask the repo, not the command output.
# (1) HEAD must differ from the last HEAD this hook saw (dedupes failed and
#     no-op commit commands); (2) HEAD's committer time must be fresh (a cold
#     start with a lost state file must not nudge on an old commit).
cur=$(git -C "$PROJ" rev-parse HEAD 2>/dev/null)
[ -n "$cur" ] || exit 0
state_dir="$HOME/.claude/tmp"
mkdir -p "$state_dir" 2>/dev/null
state="$state_dir/commit-sync-$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
last=$(cat "$state" 2>/dev/null || echo "")
printf '%s' "$cur" > "$state" 2>/dev/null
[ "$cur" = "$last" ] && exit 0   # no new commit since last check -> silent
now=$(date +%s)
ct=$(git -C "$PROJ" log -1 --format=%ct 2>/dev/null || echo 0)
[ $((now - ct)) -lt 300 ] || exit 0   # last commit is not fresh -> the command did not commit

# If the commit that just landed already included the journal - the merged page OR a
# per-session page on the memory/daily/ shelf - memory is handled -> silent.
if (cd "$PROJ" && git show --name-only --pretty=format: HEAD 2>/dev/null) | grep -qE "memory/daily(\.md|/)"; then
  exit 0
fi

# If the journal was touched in the last 20 min AND actually carries uncommitted edits,
# it's fresh (updated this session) -> silent. mtime alone is not evidence of logging (v5).
# JREF is the most recently written journal page: daily.md or a shelf page (v7).
JREF="$DAILY"
for jf in "$PROJ"/memory/daily/*.md; do
  [ -e "$jf" ] || continue
  case "$(basename "$jf")" in README.md) continue;; esac
  [ "$jf" -nt "$JREF" ] && JREF="$jf"
done
# Probe THAT page for real uncommitted edits - not the whole shelf: an untracked
# memory/daily/ folder would otherwise read as "the journal was edited" forever.
mt=$(stat -f%m "$JREF" 2>/dev/null || stat -c%Y "$JREF" 2>/dev/null || echo 0)
if [ $((now - mt)) -lt 1200 ] && [ -n "$(git -C "$PROJ" status --porcelain -- "${JREF#$PROJ/}" 2>/dev/null)" ]; then
  exit 0
fi

# Otherwise, nudge. Claude has the context to know if this commit was milestone-worthy.
/usr/bin/python3 -c '
import json
msg = ("A git commit just succeeded, but the memory notebook was not updated as part of it. "
       "If this commit represents real work (a milestone or a meaningful change), close it out now: "
       "write a session entry on this session\x27s own journal page under memory/daily/ (never straight "
       "into memory/daily.md), log any decisions in memory/decisions.md, refresh "
       "project-status.html (understanding/roadmap/objectives/recent-decisions + lastUpdated) from their "
       "real homes, keep pages/pages.json accurate if any people-facing page was added, renamed, or "
       "retired, then commit those memory files and tell the user in one line what you logged. "
       "If the commit was trivial (a typo, formatting, or a work-in-progress checkpoint), ignore this.")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))
'
exit 0
