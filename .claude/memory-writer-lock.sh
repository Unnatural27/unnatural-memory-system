#!/bin/bash
# Single-writer lock for the memory notebook. v3. PORTABLE / self-locating.
#
# WHY: two Claude sessions open on one project share ONE working tree, so they never
# "merge" - they overwrite each other. A file changes between one session's Read and
# Edit; one session's commit sweeps up another's mid-flight work; a stray `git restore`
# throws it away. Prose and a HEAD re-check only ever detected this AFTER the damage.
#
# v1 guarded the Edit/Write TOOLS. v2 (2026-07-27) replaced that with "classify by what
# a command WRITES", after an incident where both sessions wrote memory/ through shell
# redirects, no claim was ever taken, and the commit warning - which needed a claim to
# exist - never fired either. Two layers of defence, both inert, looking like two.
#
# v3 (2026-07-27) is the review pass on v2. It fixes five ways v2 was still evadable or
# wrong, and adds the layer that does not depend on parsing at all:
#   1. Checks are INDEPENDENT, not if/elif. v2 classified a command as exactly one
#      thing, so `echo x >> memory/daily.md && git add -A` was classified as a notebook
#      write and the broad-staging check never ran - the headline guard, bypassed by an
#      ordinary close-out shape. (Same bug class as the one v2 was written to fix.)
#   2. DESTRUCTIVE git is guarded too: `git checkout/restore .`, `git reset --hard`,
#      `git stash`, `git clean -f` discard another session's uncommitted work outright,
#      which is worse than sweeping it into a commit. v2 guarded only the staging verbs.
#   3. The touched-path ledger is keyed BOTH ways (session id and transcript), exactly
#      like the "is this claim mine" test. v2 keyed it on session id alone, so a /clear
#      or a compaction handed the same window a fresh ledger and then told it its own
#      files were foreign work - which trained sessions to reach for --adopt.
#   4. --adopt is ONE-SHOT and bound to the session that ran it (the hook sees the
#      `--adopt` command go by and stamps the owner). v2 left a project-wide hole open
#      for an hour: one session's escape hatch unblocked every other session.
#   5. `git -C <other repo>` is judged against THAT repo, not this one (v2 denied a
#      command aimed at a different repository based on this project's dirty state),
#      and a leading `cd <dir> &&` is honoured when resolving relative write targets.
#      v3.1 (2026-08-06) extends this the same way to the session's persistent Bash
#      working directory (the hook JSON's cwd) - not just an explicit leading `cd` -
#      so a command with no `cd` at all is still judged against where it actually
#      runs. A genuinely foreign repository gets a one-line "not guarded here" notice
#      instead of a silent pass, so the session knows the command was never checked.
#   6. PostToolUse BACKSTOP: after every shell command, compare the shared notebook
#      pages against a stored baseline. If one changed while this session did not hold
#      the claim, say so. It cannot prevent - it runs after the fact - but it observes
#      the filesystem instead of parsing intent, so NO write shape can evade it. This is
#      the layer that does not share a failure mode with the parser. Kept cheap: pure
#      shell stat comparison, and python is only spawned when something actually moved.
#
# JOBS, dispatched on hook_event_name:
#  PreToolUse (Edit|Write|NotebookEdit|MultiEdit|Bash): deny a write to a shared notebook
#      page while another live session holds the claim; deny broad staging or a
#      destructive git command while the tree holds paths this session did not write.
#      Otherwise claim lazily, record the touched paths, and allow.
#  PostToolUse (Bash): the backstop above.
#  SessionEnd: release the claim if this session holds it, and drop its ledgers.
#
# FAIL-OPEN BY DESIGN: bad JSON, no HOME, no python, no git, an unreadable lock, an
# unknown event, a command it cannot parse - all exit 0 = allow. It may only ever deny
# in the single case it has positively identified. A wrongly-denied write is announced
# and recoverable; a wrongly-allowed one is the corruption this exists to prevent.
#
# CRASH RECOVERY: the claim records the holder's transcript file, which Claude Code
# writes to continuously. If that file has been cold for STALE_SECS the holder is gone,
# and the next session takes the claim over by itself, announcing it in one line.
#
# All state lives OUTSIDE the repo (~/.claude/tmp/, keyed by project path) so it never
# appears in `git status`, never travels in a copied folder, and can never become a
# merge conflict. Keyed by PATH, so two git worktrees do NOT share a claim: do notebook
# work in the main tree (see the protocol block's "Two sessions, one folder").
#
# Escape hatches - a session can run these itself, no developer needed:
#   bash .claude/memory-writer-lock.sh --status   # who holds the notebook?
#   bash .claude/memory-writer-lock.sh --release <your-session-id>   # drop YOUR claim
#   bash .claude/memory-writer-lock.sh --release --force             # drop it regardless
#     (bare --release still works, but REFUSES when a different, still-live session holds
#      the claim - releasing that would expose its in-flight work. A cold holder is always
#      released: that is the crash-recovery path.)
#   bash .claude/memory-writer-lock.sh --adopt    # "every change here right now is mine"
# Portable stat: BSD (macOS) -f, GNU (Linux) -c fallback.

PROJ="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
STALE_SECS=1800   # holder transcript cold this long = that session is gone, take over
ADOPT_SECS=600    # an unclaimed --adopt expires this fast (it is also one-shot)

state_dir="$HOME/.claude/tmp"
mkdir -p "$state_dir" 2>/dev/null || exit 0
PHASH="$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
LOCK="$state_dir/memory-lock-$PHASH"
ADOPT="$state_dir/memory-adopt-$PHASH"
ADOPT_OWNER="$state_dir/memory-adopt-owner-$PHASH"
STATE="$state_dir/memory-state-$PHASH"

# The shared pages the backstop watches. A session's own memory/daily/ page is NOT here:
# that shelf is one file per session by design and has no contention to detect.
SHARED_PAGES="memory/CURRENT.md memory/decisions.md memory/index.md memory/open-threads.md memory/history.md memory/daily.md memory/lessons.md project-status.html"

lock_field () { sed -n "s/^$1=//p" "$LOCK" 2>/dev/null | head -1; }
fmtime ()     { stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0; }
fsize ()      { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# ---- manual escape hatches (argv mode: never reads stdin) -------------------
case "${1:-}" in
  --status)
    if [ -f "$LOCK" ]; then
      echo "Notebook claim for $(basename "$PROJ"):"
      cat "$LOCK"
    else
      echo "No session currently claims $(basename "$PROJ")'s notebook."
    fi
    if [ -f "$ADOPT" ]; then
      echo "An --adopt is pending ($(wc -l < "$ADOPT" | tr -d ' ') path(s)) - it is one-shot and is consumed by the next broad command."
    fi
    exit 0 ;;
  --release)
    # v3.2 (2026-08-16): --release used to drop the claim WHOEVER held it, with no
    # ownership test, because argv mode never reads the hook JSON and so cannot see who
    # is calling. Close-out step 10 runs this unconditionally, so a session closing out
    # while ANOTHER live session held the notebook silently dropped that session's claim
    # - observed for real on 2026-08-16 (549d306a closing out released 7ec0e085's claim).
    # Fix: the caller names itself. A live holder is only released by itself or --force;
    # a stale holder is still released by anyone, which is the crash-recovery path.
    want="${2:-}"
    if [ ! -f "$LOCK" ]; then
      echo "No claim to release for $(basename "$PROJ")."
      exit 0
    fi
    rel_sid="$(lock_field session)"
    rel_trans="$(lock_field transcript)"
    rel_when="$(lock_field claimed_human)"
    rel_live=0
    if [ -n "$rel_trans" ] && [ -f "$rel_trans" ]; then
      [ $(( $(date +%s) - $(fmtime "$rel_trans") )) -lt "$STALE_SECS" ] && rel_live=1
    fi
    rel_mine=0
    if [ -n "$want" ] && [ "$want" != "--force" ] && [ -n "$rel_sid" ]; then
      # accept a short id or the full uuid, in either direction
      case "$rel_sid" in "$want"*) rel_mine=1 ;; esac
      case "$want" in "$rel_sid"*) rel_mine=1 ;; esac
    fi
    if [ "$rel_live" = "1" ] && [ "$rel_mine" = "0" ] && [ "$want" != "--force" ]; then
      echo "REFUSED: the notebook claim for $(basename "$PROJ") is held by a session that is still live."
      echo "  holder:  $rel_sid"
      echo "  claimed: $rel_when"
      echo "Releasing it would let a third session write over that session's in-flight work."
      echo "If the claim is YOURS, name yourself:  bash .claude/memory-writer-lock.sh --release <your-session-id>"
      echo "If you are certain it is abandoned:    bash .claude/memory-writer-lock.sh --release --force"
      exit 0
    fi
    rm -f "$LOCK" 2>/dev/null
    if [ "$rel_live" = "1" ]; then
      echo "Released the notebook claim for $(basename "$PROJ") (holder $rel_sid). The next notebook write re-claims it."
    else
      echo "Released the notebook claim for $(basename "$PROJ") - holder $rel_sid was cold, so that session is gone. The next notebook write re-claims it."
    fi
    exit 0 ;;
  --adopt)
    if ! git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1; then
      echo "$(basename "$PROJ") is not a git repo - there is nothing to adopt."
      exit 0
    fi
    git -C "$PROJ" status --porcelain -z -uall 2>/dev/null | /usr/bin/python3 -c '
import sys
raw = sys.stdin.buffer.read().decode("utf-8", "replace")
out = []
for f in raw.split("\x00"):
    if not f: continue
    out.append(f[3:] if len(f) > 3 and f[2] == " " else f)
out = [p for p in out if p]
sys.stdout.write("\n".join(out) + ("\n" if out else ""))
' > "$ADOPT" 2>/dev/null
    n="$(wc -l < "$ADOPT" 2>/dev/null | tr -d ' ')"
    echo "Adopted ${n:-0} changed path(s) in $(basename "$PROJ") as this session's own work."
    echo "This is ONE-SHOT: the next broad command (git add -A / . / <dir>/, git commit -a) uses it and it is gone."
    if [ -f "$ADOPT_OWNER" ]; then
      echo "It is bound to the session that ran this command - no other session can use it."
    else
      echo "No owning session was recorded, so it expires in $((ADOPT_SECS / 60)) minutes."
    fi
    exit 0 ;;
esac

# ---- hook mode -------------------------------------------------------------
input=$(cat)
[ -n "$input" ] || exit 0

# PostToolUse backstop. The event name is read from the PARSED JSON, never matched as a
# substring of the raw input: a Bash command is attacker-shaped text that lands in the
# same blob, so `case "$input" in *PostToolUse*)` let ANY command carrying that string
# (`echo PostToolUse >> memory/daily.md`) route itself into this branch and skip every
# guard below. The cheap glob is kept only as a pre-filter - it can produce a false
# positive, which the parse then corrects, but never a false negative.
case "$input" in
  *PostToolUse*)
    { IFS= read -r PEV; IFS= read -r PSID; IFS= read -r PTR; } < <(
      printf '%s' "$input" | /usr/bin/python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
if not isinstance(d, dict): d = {}
for k in ("hook_event_name", "session_id", "transcript_path"):
    print(str(d.get(k) or "").replace("\n", " "))
' 2>/dev/null)
    [ "${PEV:-}" = "PostToolUse" ] || PEV=""      # not really a PostToolUse -> fall through
    ;;
esac
if [ "${PEV:-}" = "PostToolUse" ]; then
    [ -d "$PROJ/memory" ] || exit 0        # not a memory project -> nothing to watch
    # ONE stat call for every watched page, not two per page: this runs after every
    # shell command, so the quiet path has to cost almost nothing. A per-file loop of
    # stat+grep was 24 subprocesses and ~125 ms; this is two and ~10 ms.
    SP=()
    for rel in $SHARED_PAGES; do SP+=("$PROJ/$rel"); done
    snap="$(stat -f '%N|%m|%z' "${SP[@]}" 2>/dev/null)"
    [ -n "$snap" ] || snap="$(stat -c '%n|%Y|%s' "${SP[@]}" 2>/dev/null)"   # GNU fallback
    [ -n "$snap" ] || exit 0
    old=""; [ -f "$STATE" ] && old="$(<"$STATE")"                          # builtin, no subprocess
    printf '%s\n' "$snap" > "$STATE" 2>/dev/null
    [ -n "$old" ] || exit 0                # first run just seeds the baseline
    [ "$old" != "$snap" ] || exit 0        # nothing moved - the overwhelmingly common case
    # Something moved. Only now is it worth spending a python to ask whose it was.
    printf '%s' "$input" | /usr/bin/python3 -c '
import sys, os, json, re
lock, oldsnap, newsnap = sys.argv[1], sys.argv[2], sys.argv[3]

def parse(s):
    out = {}
    for line in s.splitlines():
        parts = line.rsplit("|", 2)
        if len(parts) == 3: out[parts[0]] = (parts[1], parts[2])
    return out
o, n = parse(oldsnap), parse(newsnap)
drift = sorted(set(o) ^ set(n)) + sorted(k for k in o if k in n and o[k] != n[k])
drift = [os.path.basename(os.path.dirname(p)) + "/" + os.path.basename(p) for p in drift]
if not drift: raise SystemExit(0)
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(0)
if not isinstance(d, dict) or d.get("hook_event_name") != "PostToolUse": raise SystemExit(0)
sid   = str(d.get("session_id") or "")
trans = str(d.get("transcript_path") or "")
hs = ht = ""
try:
    for line in open(lock):
        if line.startswith("session="):    hs = line[8:].strip()
        elif line.startswith("transcript="): ht = line[11:].strip()
except Exception:
    pass
mine = (hs and sid and hs == sid) or (ht and trans and ht == trans)
if mine: raise SystemExit(0)          # the claim holder writing its own notebook: fine
who = ("another live session holds the notebook claim"
       if hs else "no session held the notebook claim")
msg = ("NOTEBOOK CHANGED WITHOUT THE CLAIM: %s changed during that command, but %s and it was not "
       "this session. Two things this can mean, and both need a look BEFORE you write more:\n"
       "  1. Another session is editing the notebook in this same folder right now - stop and "
       "reconcile rather than writing over it.\n"
       "  2. A shell command from THIS session wrote a shared page in a shape the guard did not "
       "recognise (a path built from a variable, an unusual tool). The write happened; it simply "
       "was not checked. Re-read the file and confirm you did not clobber anything.\n"
       "This check watches the files themselves, so it sees writes the command parser misses - "
       "which is exactly why it exists. Run: bash .claude/memory-writer-lock.sh --status"
       % (", ".join(drift), who))
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))
' "$LOCK" "$old" "$snap" 2>/dev/null
  exit 0
fi

PEND="$state_dir/memory-touched-$PHASH-pending.$$"
trap 'rm -f "$PEND" 2>/dev/null' EXIT

{ IFS= read -r EVENT;  IFS= read -r SID;   IFS= read -r TRANS; IFS= read -r SHORT
  IFS= read -r TSHORT; IFS= read -r GPATH; IFS= read -r BROAD; IFS= read -r DESTR
  IFS= read -r ISCOMMIT; IFS= read -r GITC; IFS= read -r ADOPTCALL; IFS= read -r BASEDIR; } < <(
  printf '%s' "$input" | /usr/bin/python3 -c '
import sys, os, re, json

PROJ, PEND = sys.argv[1], sys.argv[2]

def emit(*vals):
    for v in vals:
        sys.stdout.write(str(v).replace("\n", " ") + "\n")

try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)              # unparseable -> no output -> bash fails open
if not isinstance(d, dict):
    raise SystemExit(0)

event = str(d.get("hook_event_name") or "")
sid   = str(d.get("session_id") or "")
trans = str(d.get("transcript_path") or "")
cwd   = str(d.get("cwd") or "")
tool  = str(d.get("tool_name") or "")
ti    = d.get("tool_input")
if not isinstance(ti, dict): ti = {}
cmd = ti.get("command"); cmd = cmd if isinstance(cmd, str) else ""
fp  = ti.get("file_path") or ti.get("notebook_path") or ""
fp  = fp if isinstance(fp, str) else ""

# Stable short ids, DERIVED from the harness - never invented. BOTH are kept: a /clear
# or a compaction changes the session id while the transcript stays, and a resume does
# the reverse. The ledger is keyed on both for exactly the reason the claim test is.
def shorten(s):
    return re.sub(r"[^A-Za-z0-9]", "", s)[:8]
short  = shorten(sid)
tshort = shorten(os.path.basename(trans).split(".")[0]) if trans else ""

# BASE starts at this session ACTUAL working directory - the hook JSON cwd field -
# not always this project. The Bash tool cwd persists across commands, so a command
# with no leading `cd` at all can still be running somewhere else entirely. Old
# fixtures (the harness) send no cwd, so PROJ remains the fallback exactly as before.
BASE = PROJ
if cwd and os.path.isabs(cwd) and os.path.isdir(cwd): BASE = os.path.normpath(cwd)
# A leading `cd X &&` changes what a relative path means for the rest of the command.
# Honouring it fixes a false negative (cd memory && echo x >> daily.md) AND a false
# positive (cd /somewhere/else && echo x >> daily.md is not this project at all). A
# relative cd target resolves against BASE (the real cwd), not always PROJ.
mcd = re.match(r"\s*cd\s+(\"[^\"]+\"|\x27[^\x27]+\x27|[^\s;&|]+)\s*(?:&&|;)", cmd)
if mcd:
    b = mcd.group(1).strip("\x27\"")
    if not b.startswith("-") and "$" not in b:
        if b.startswith("~/"): b = os.path.expanduser(b)
        BASE = b if os.path.isabs(b) else os.path.normpath(os.path.join(BASE, b))

def norm(p, base=None):
    """A write target -> its repo-relative path, or None if it is not inside PROJ."""
    if not isinstance(p, str): return None
    p = p.strip().strip("\x27\"").strip()
    if not p or p.startswith("-"): return None
    p = p.replace("${CLAUDE_PROJECT_DIR}", PROJ).replace("$CLAUDE_PROJECT_DIR", PROJ)
    if p.startswith("~/"): p = os.path.expanduser(p)
    if "$" in p or "*" in p or "?" in p: return None   # unexpanded/globbed -> cannot know
    if not os.path.isabs(p): p = os.path.join(base or PROJ, p)
    p = os.path.normpath(p)
    if p == PROJ or not p.startswith(PROJ + os.sep): return None
    return p[len(PROJ) + 1:]

# ---- what does this shell command WRITE to? --------------------------------
# Conservative and pattern-based. Anything it cannot positively identify is simply
# not returned, which means allowed - the fail-open rule, applied to parsing.
REDIR   = re.compile(r"(?<![0-9<>&])[0-9]?>>?\s*(?!&)(\"[^\"]*\"|\x27[^\x27]*\x27|[^\s;|&<>()]+)")
# Any interpreter, not just python: perl -e / ruby -e / node -e write files too, and a
# guard that knows one language is a guard that knows none. These feed the LOOSE list
# only, so a false positive costs a recoverable deny and can never grant ownership.
PYWRITE = re.compile(r"open\s*\([^)]*[\"\x27][wax]b?\+?[\"\x27]|\.write\s*\(|write_text\s*\("
                     r"|write_bytes\s*\("
                     r"|writelines\s*\(|json\.dump\s*\(|shutil\.(copy|move)|os\.(replace|rename)"
                     r"|File\.(write|open|new)|IO\.write"
                     r"|writeFileSync|appendFileSync|createWriteStream"
                     r"|q\{>>?\}|[\"\x27]>>?[\"\x27]")
PYCALL  = re.compile(r"(^|[\s;|&(])(/usr/bin/)?(python3?|perl|ruby|node|deno|php)\b")
# perl writes its paths as q{...} as often as it quotes them
BRACED  = re.compile(r"q?\{([^{}\n]+)\}")
# A quoted literal - either backslash-escaped by the outer shell
# (python3 -c "open(\"memory/x\",\"w\")") or plain. The escaped form is a separate,
# backslash-REQUIRED alternative and neither body may contain a backslash: that way the
# outer un-escaped quote cannot swallow the escaped literal sitting inside it.
QUOTED  = re.compile(r"\\[\"\x27]([^\"\x27\\\n]+)\\[\"\x27]"
                     r"|[\"\x27]([^\"\x27\\\n]+)[\"\x27]")
# A LITERAL path handed to a write-mode call is a demonstrable write, not a mention, so
# it is safe to OWN and not merely to guard. Without this, a notebook page edited by a
# script - open("memory/CURRENT.md","w") - never entered the ledger, and the very next
# broad git command treated this very session as foreign work. Mode is required: an
# open() with no mode, or mode "r", is a READ and stays out (that is the red-team case).
WRITE_LIT = re.compile(
    r"open\s*\(\s*\\?[\"\x27]([^\"\x27\\\n]+)\\?[\"\x27]\s*,\s*\\?[\"\x27][wax]b?\+?\\?[\"\x27]"
    r"|(?:writeFileSync|appendFileSync|createWriteStream)\s*\(\s*\\?[\"\x27]([^\"\x27\\\n]+)\\?[\"\x27]"
    r"|\\?[\"\x27]([^\"\x27\\\n]+)\\?[\"\x27]\s*\)?\s*\.\s*(?:write_text|write_bytes)\s*\(")
SEGSPLIT = r"[;\n]|&&|\|\||[|&]"

def toks_of(seg):
    return [t.strip("\x27\"") for t in re.findall(r"\"[^\"]*\"|\x27[^\x27]*\x27|\S+", seg)]

def write_targets(c):
    """-> (precise, loose).

    precise = paths this command demonstrably writes. Safe to record in the ledger as
              "this session owns it".
    loose   = paths a python one-liner merely MENTIONS while writing something. Good
              enough to guard on (over-blocking is the safe direction) but NOT good
              enough to own: `python3 -c "open(out,\x27w\x27).write(open(FOREIGN).read())"`
              only READS the foreign file, and recording it would hand this session
              ownership of another session\x27s work - which is what the broad-staging
              guard exists to prevent.

    The one exception is WRITE_LIT: a literal path with an explicit write mode is not a
    mention, it is the write itself, so it goes in precise. A path built from a variable
    stays loose - guarded, but not owned - and --adopt is the answer for that shape.

    ACCEPTED TRADEOFF: this whole function runs PreToolUse, before the command has
    actually executed, so a command matched by WRITE_LIT still claims ledger ownership
    even if it goes on to fail at runtime (bad path, permission error, syntax error, a
    caught exception before the write happens). Static parsing has no way to know the
    outcome ahead of time; this is a known and accepted limitation, not a bug to fix here.
    """
    hits, loose = [], []
    for m in REDIR.finditer(c):
        hits.append(m.group(1))
    for seg in re.split(SEGSPLIT, c):
        toks = toks_of(seg)
        if not toks: continue
        base = os.path.basename(toks[0])
        rest = toks[1:]
        plain = [t for t in rest if not t.startswith("-")]
        if base == "tee":
            hits += plain
        elif base in ("sed", "gsed", "perl") and any(
                t == "--in-place" or t.startswith("-i") or (re.fullmatch(r"-[A-Za-z]+", t) and "i" in t)
                for t in rest if t.startswith("-")):
            hits += plain[1:]            # drop the script/expression, keep the files
        elif base in ("cp", "mv", "install", "rsync", "ditto") and len(plain) >= 2:
            hits.append(plain[-1])       # the destination
        elif base == "dd":
            hits += [t[3:] for t in rest if t.startswith("of=")]
        elif base in ("truncate",) and plain:
            hits += plain
        elif base == "git" and len(rest) >= 2:
            # `git checkout -- <path>` / `git restore <path>` OVERWRITE that path from
            # the index. Naming one file is allowed (same principle as a scoped commit),
            # but it is still a WRITE, so the shared-page guard must see it.
            j = 0
            while j < len(rest) and rest[j].startswith("-"):
                j += 2 if rest[j] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace") else 1
            if j < len(rest) and rest[j] in ("checkout", "restore"):
                hits += [t for t in rest[j + 1:] if not t.startswith("-") and t != "--"]
    # A python invocation that writes SOMETHING: treat every path-shaped literal in the
    # command (heredoc body included) as a candidate target. Over-collecting is safe -
    # norm() drops anything outside the project and the guard only fires on memory/.
    if PYCALL.search(c) and PYWRITE.search(c):
        cands = [m.group(1) or m.group(2) for m in QUOTED.finditer(c)]
        cands += [m.group(1) for m in BRACED.finditer(c)]
        for s in cands:
            if s and ("/" in s or s.endswith((".md", ".html", ".json", ".txt"))):
                loose.append(s)
        # ...and the subset that is demonstrably written, not merely named, is OWNED.
        for m in WRITE_LIT.finditer(c):
            s = m.group(1) or m.group(2) or m.group(3)
            if s: hits.append(s)
    return hits, loose

# ---- git commands that stage, or destroy, more than this session owns ------
def _wide(s):
    return s in (".", "./", ":/", "*", ":/*")

def git_ops(c):
    """-> (broad, destructive, gitc). Each of broad/destructive: None | "*" | [dirs]."""
    broad = destr = None
    gitc = ""
    for seg in re.split(SEGSPLIT, c):
        toks = toks_of(seg)
        if not toks or os.path.basename(toks[0]) != "git": continue
        i = 1
        while i < len(toks) and toks[i].startswith("-"):
            if toks[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace"):
                if toks[i] == "-C" and i + 1 < len(toks): gitc = toks[i + 1]
                i += 2
            else:
                i += 1
        if i >= len(toks): continue
        sub, rest = toks[i], toks[i + 1:]
        flags = [t for t in rest if t.startswith("-")]
        specs = [t for t in rest if not t.startswith("-") and t != "--"]
        has_dashdash = "--" in rest

        def dirs_of(ss):
            return [s.rstrip("/") for s in ss
                    if s.endswith("/") or os.path.isdir(os.path.join(PROJ, s))]

        if sub == "add":
            for t in flags:
                if t in ("-A", "--all", "-u", "--update", "--no-ignore-removal"): broad = "*"
                elif re.fullmatch(r"-[A-Za-z]+", t) and ("A" in t or "u" in t): broad = "*"
            if broad != "*" and specs:
                if any(_wide(s) for s in specs): broad = "*"
                else:
                    dd = dirs_of(specs)
                    if dd: broad = dd
        elif sub == "commit":
            for t in rest:
                if t in ("-a", "--all"): broad = "*"
                elif re.fullmatch(r"-[A-Za-z]+", t) and "a" in t: broad = "*"
        elif sub == "reset":
            if "--hard" in flags: destr = "*"
        elif sub == "clean":
            if any(re.fullmatch(r"-[A-Za-z]+", t) and "f" in t for t in flags) or "--force" in flags:
                if specs and not any(_wide(s) for s in specs):
                    dd = dirs_of(specs)
                    destr = dd if dd else destr
                else:
                    destr = "*"
        elif sub == "stash":
            head = specs[0] if specs else ""
            if head in ("", "push", "save"):
                # `git stash -- <paths>` is scoped; anything else takes the whole tree
                tail = [s for s in specs[1:]] if head in ("push", "save") else specs
                if has_dashdash and tail:
                    dd = dirs_of(tail)
                    destr = dd if dd else destr
                else:
                    destr = "*"
        elif sub == "rm":
            # `git rm -r --cached .` empties the index; the next commit then records a
            # deletion of every tracked file, including another session\x27s.
            if any(re.fullmatch(r"-[A-Za-z]+", t) and "r" in t for t in flags) or any(_wide(s) for s in specs):
                broad = "*"
            elif specs:
                dd = dirs_of(specs)
                if dd: broad = dd
        elif sub in ("checkout", "restore", "switch"):
            # A forced switch/checkout throws away local changes wholesale, pathspec or
            # not - `git switch -f main` is `reset --hard` wearing a different hat.
            if any(t in ("-f", "--force", "--discard-changes") for t in flags) or \
               any(re.fullmatch(r"-[A-Za-z]+", t) and "f" in t for t in flags):
                destr = "*"
                continue
            if sub == "switch": continue          # a plain branch switch is not a discard
            # A branch name and a directory look alike, so `checkout` only counts as a
            # discard when it is unambiguous: an explicit `--`, a wide spec, or a spec
            # that ends in "/". `restore` never takes a branch, so any spec counts.
            cand = specs if (sub == "restore" or has_dashdash) else [s for s in specs if _wide(s) or s.endswith("/")]
            if any(_wide(s) for s in cand):
                destr = "*"
            else:
                dd = dirs_of(cand)
                if dd: destr = dd
    return broad, destr, gitc

def guarded(r):
    """The shared notebook + its visible mirror. My own journal page is NOT shared."""
    if r == "project-status.html": return True
    if not r.startswith("memory/"): return False
    if r.startswith("memory/daily/"):
        # One journal file per session, so there is nothing to protect - unless this is
        # somebody ELSE\x27s page, which is not mine to write. Match the id as a whole
        # token, never as a substring, so a short id cannot claim another page.
        parts = re.split(r"[^A-Za-z0-9]+", os.path.basename(r))
        return not ((short and short in parts) or (tshort and tshort in parts))
    return True

targets = [fp] if (tool in ("Edit", "Write", "NotebookEdit", "MultiEdit") and fp) else []
loose_targets = []
if tool == "Bash" and cmd:
    t_precise, t_loose = write_targets(cmd)
    targets += t_precise
    loose_targets = t_loose

def resolve(ts):
    out, seen = [], set()
    for t in ts:
        r = norm(t, BASE)
        if r and r not in seen:
            seen.add(r); out.append(r)
    return out

owned_rel = resolve(targets)                       # what this session may CLAIM to own
rel = owned_rel + [r for r in resolve(loose_targets) if r not in owned_rel]   # what to GUARD

# The ledger only wants real files: a parsed fragment that is not a plausible path
# (a sed expression, a stray token) is dropped rather than recorded as "touched".
def plausible(r):
    full = os.path.join(PROJ, r)
    return os.path.exists(full) or os.path.isdir(os.path.dirname(full))

gpath, broad, destr, gitc, iscommit, adoptcall = "", "", "", "", "0", "0"
if event == "PreToolUse":
    # INDEPENDENT checks - never if/elif. A single command can be both a notebook write
    # and a broad stage, and v2 only ever reported the first of those.
    g = [r for r in rel if guarded(r)]
    if g: gpath = g[0]
    if tool == "Bash" and cmd:
        b, dz, gitc = git_ops(cmd)
        if b is not None:   broad = "*" if b == "*" else "\t".join(b)
        if dz is not None:  destr = "*" if dz == "*" else "\t".join(dz)
        if re.search(r"(^|[\s;|&])git\s+.{0,40}?\bcommit\b", cmd): iscommit = "1"
        if "memory-writer-lock" in cmd and "--adopt" in cmd: adoptcall = "1"

try:
    with open(PEND, "w") as fh:
        for r in owned_rel:                        # ledger gets only the precise set
            if plausible(r): fh.write(r + "\n")
except Exception:
    pass

emit(event, sid, trans, short, tshort, gpath, broad, destr, iscommit, gitc, adoptcall, BASE)
' "$PROJ" "$PEND" 2>/dev/null)
[ -n "${EVENT:-}" ] || exit 0   # unparseable input -> fail open, allow

# Two ledgers, one per identifier, both written and both read. A /clear changes the
# session id but not the transcript; a resume does the reverse. Keying on one alone is
# what made v2 tell a compacted session that its own files were somebody else's work.
LEDGERS=""
[ -n "${SHORT:-}" ]  && LEDGERS="$LEDGERS $state_dir/memory-touched-$PHASH-s$SHORT.list"
[ -n "${TSHORT:-}" ] && LEDGERS="$LEDGERS $state_dir/memory-touched-$PHASH-t$TSHORT.list"
[ -n "$LEDGERS" ] || LEDGERS="$state_dir/memory-touched-$PHASH-unknown.list"

record () {
  [ -s "$PEND" ] || return 0
  for L in $LEDGERS; do
    # append, then de-duplicate in place: a long session editing one file 200 times
    # should not carry 200 identical lines.
    cat "$PEND" >> "$L" 2>/dev/null
    if [ -f "$L" ]; then
      sort -u "$L" > "$L.dedup" 2>/dev/null && mv -f "$L.dedup" "$L" 2>/dev/null
    fi
  done
  return 0
}

# ---- who holds the claim, and are they still alive? ------------------------
holder_sid="";  holder_trans="";  holder_when=""
if [ -f "$LOCK" ]; then
  holder_sid="$(lock_field session)"
  holder_trans="$(lock_field transcript)"
  holder_when="$(lock_field claimed_human)"
fi

# Mine if EITHER the session id or the transcript path matches: a /clear, a
# compaction or a resume can change one of those without changing the other, and
# treating a continuation of my own window as a stranger would deny my own writes.
mine=0
[ -n "$holder_sid" ]   && [ -n "${SID:-}" ]   && [ "$holder_sid" = "$SID" ]     && mine=1
[ -n "$holder_trans" ] && [ -n "${TRANS:-}" ] && [ "$holder_trans" = "$TRANS" ] && mine=1

# Claude Code writes the holder's transcript continuously, so a cold transcript
# means that session is gone. A missing/unnamed transcript also counts as gone.
holder_live=0
if [ -n "$holder_trans" ] && [ -f "$holder_trans" ]; then
  [ $(( $(date +%s) - $(fmtime "$holder_trans") )) -lt "$STALE_SECS" ] && holder_live=1
fi

# Re-claiming on every guarded write keeps the recorded identity current across a
# /clear or a compaction. When the claim is already mine, the ORIGINAL claim time is
# carried over rather than reset - "claimed at" has to mean claimed, not last-written,
# because that timestamp is what the other session gets told.
claim () {
  [ -n "${SID:-}${TRANS:-}" ] || return 0   # nothing to identify us with -> don't claim
  when_epoch=""; when_human=""
  if [ "$mine" = "1" ] && [ -f "$LOCK" ]; then
    when_epoch="$(lock_field claimed)"
    when_human="$(lock_field claimed_human)"
  fi
  [ -n "$when_epoch" ] || when_epoch="$(date +%s)"
  [ -n "$when_human" ] || when_human="$(date '+%Y-%m-%d %H:%M')"
  # Written to a same-dir temp, then an atomic rename (2026-08-04 audit): a reader
  # can never observe a half-written claim file. Honest residual: two sessions'
  # very FIRST claims racing in the same instant is still last-writer-wins - this
  # is a fail-open safety layer, not a mutex, and the PostToolUse backstop plus
  # the deny-on-live-holder check above are the layers that catch that shape.
  claim_tmp="$LOCK.tmp.$$"
  {
    echo "session=$SID"
    echo "transcript=$TRANS"
    echo "claimed=$when_epoch"
    echo "claimed_human=$when_human"
    echo "project=$PROJ"
  } > "$claim_tmp" 2>/dev/null || { rm -f "$claim_tmp" 2>/dev/null; return 0; }
  mv -f "$claim_tmp" "$LOCK" 2>/dev/null || rm -f "$claim_tmp" 2>/dev/null
}

# ---- SessionEnd: release if it is mine, and drop this session's ledgers -----
if [ "$EVENT" = "SessionEnd" ]; then
  [ "$mine" = "1" ] && rm -f "$LOCK" 2>/dev/null
  for L in $LEDGERS; do rm -f "$L" 2>/dev/null; done
  # crashed sessions leave ledgers behind; sweep anything over a week old
  find "$state_dir" -maxdepth 1 -name "memory-touched-$PHASH-*" -mtime +7 -delete 2>/dev/null
  exit 0
fi

[ "$EVENT" = "PreToolUse" ] || exit 0

# A session running `--adopt` goes through this hook first, which is the only moment the
# adopt can be tied to an identity - the argv-mode run that follows has no session at all.
if [ "${ADOPTCALL:-0}" = "1" ]; then
  { echo "session=$SID"; echo "transcript=$TRANS"; } > "$ADOPT_OWNER" 2>/dev/null
fi

# ---- CHECK 1: a write to a shared notebook page ----------------------------
# Runs INDEPENDENTLY of the git checks below - a command can be both.
if [ -n "${GPATH:-}" ]; then
  if [ -f "$LOCK" ] && [ "$mine" = "0" ] && [ "$holder_live" = "1" ]; then
    /usr/bin/python3 -c '
import json, sys
msg = ("SINGLE-WRITER LOCK: another Claude session claimed the memory notebook for this project "
       "at %s and is still active. Two sessions writing one notebook is what corrupts it, so "
       "this write to %s is blocked.\n"
       "Do one of these, then tell the user in one line which:\n"
       "  1. Keep working and journal as normal: this session\x27s OWN page under memory/daily/ is "
       "never locked. Anything that belongs in a locked page goes there for now - write a blocked "
       "decision as \"DECISION: ...\" and compaction promotes it to decisions.md. Nothing is lost.\n"
       "  2. Do the notebook work in that other session instead (it has the context).\n"
       "  3. If that session is really gone, run: bash .claude/memory-writer-lock.sh --release "
       "- then retry this write.\n"
       "Nothing else is blocked: code, docs and pages in this project are all still writable, so "
       "keep working - only the shared notebook pages and project-status.html are held."
       % (sys.argv[1], sys.argv[2]))
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                         "permissionDecision": "deny",
                                         "permissionDecisionReason": msg}}))
' "${holder_when:-an earlier time}" "$GPATH" 2>/dev/null
    exit 0
  fi
fi

# ---- where does this session's git actually run? (shared by CHECK 2 & 3) ---
# BASEDIR is this session's real working directory - the hook JSON's cwd, or PROJ if
# that was not sent (old harness fixtures have no cwd, so behaviour there is
# unchanged). GITC is an explicit `git -C <dir>`, which wins over cwd, same as git
# itself. FOREIGN_REPO means the command is not aimed at this project's tree at all -
# a leading `cd`, the persistent Bash cwd, or `-C` can all cause that. v2 judged every
# git command against THIS project's dirty state regardless, which denied perfectly
# good commands aimed elsewhere; computed once here so CHECK 2 and CHECK 3 agree.
FOREIGN_REPO=0
otop=""; ptop=""
if [ -n "${BROAD:-}" ] || [ -n "${DESTR:-}" ] || [ "${ISCOMMIT:-0}" = "1" ]; then
  eff="${BASEDIR:-$PROJ}"
  if [ -n "${GITC:-}" ]; then
    case "$GITC" in /*) eff="$GITC" ;; *) eff="$eff/$GITC" ;; esac
  fi
  otop="$(git -C "$eff" rev-parse --show-toplevel 2>/dev/null)"
  ptop="$(git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null)"
  # Only judge this "foreign" when PROJ itself is a confirmed repo - if PROJ is not a
  # git repo at all, fall through unchanged to the git-dir check below (fail open).
  if [ -n "$ptop" ] && { [ -z "$otop" ] || [ "$otop" != "$ptop" ]; }; then FOREIGN_REPO=1; fi
fi

# ---- CHECK 2: broad staging / destructive git over work that is not ours ---
if [ -n "${BROAD:-}" ] || [ -n "${DESTR:-}" ]; then
  if [ "$FOREIGN_REPO" = "1" ]; then
    if [ -n "$otop" ] && [ "$otop" != "$ptop" ]; then
      # A genuinely different, real repository - say so once instead of a silent
      # skip, so the session knows this command was never checked (not that it
      # quietly passed). otop empty means the target is not a git repo at all;
      # git will error on its own there, so nothing to say.
      /usr/bin/python3 -c '
import json, sys
msg = ("NOTE: that git command runs in a different repository (%s), not this project - the "
       "memory guard only watches this project\x27s tree, so it did not check that command."
       % sys.argv[1])
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": msg}}))
' "$otop" 2>/dev/null
    fi
    # Either way: record what we know (the old -C skip lost the pending ledger paths
    # here - fixed in passing) and fail open.
    record
    exit 0
  fi
  TARGET_REPO="$PROJ"
  if git -C "$TARGET_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "${DESTR:-}" ]; then MODE="destructive"; SCOPE="$DESTR"; else MODE="staging"; SCOPE="$BROAD"; fi
    # -uall expands untracked directories to individual files, so the deny message can
    # name the foreign work and a session that wrote every file under a new directory is
    # correctly recognised as owning it. Piped straight into python and never through a
    # "$( )" - command substitution silently STRIPS the NUL separators -z relies on.
    git -C "$TARGET_REPO" status --porcelain -z -uall 2>/dev/null | /usr/bin/python3 -c '
import sys, os, json, time
ledgers, adopt, owner, scope, mode, secs, sid, trans = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]),
    sys.argv[7], sys.argv[8])

dirty = []
for f in sys.stdin.buffer.read().decode("utf-8", "replace").split("\x00"):
    if not f: continue
    dirty.append(f[3:] if len(f) > 3 and f[2] == " " else f)
dirty = [p for p in dirty if p]
if not dirty: raise SystemExit(0)

def load(p):
    try: return set(l.strip() for l in open(p) if l.strip())
    except Exception: return set()

owned = set()
for p in ledgers.split():
    owned |= load(p)

# The adopt list is ONE-SHOT and bound to the session that asked for it. An unowned
# adopt (a human ran it in a terminal) is honoured only inside a short window.
adopted, use_adopt = load(adopt), False
if adopted:
    os_ = ot = ""
    try:
        for line in open(owner):
            if line.startswith("session="):      os_ = line[8:].strip()
            elif line.startswith("transcript="): ot = line[11:].strip()
    except Exception:
        pass
    if os_ or ot:
        use_adopt = (os_ and sid and os_ == sid) or (ot and trans and ot == trans)
    else:
        try: use_adopt = (time.time() - os.path.getmtime(adopt)) <= secs
        except Exception: use_adopt = False
if use_adopt: owned |= adopted

if scope and scope != "*":
    scopes = [s for s in scope.split("\t") if s]
    dirty = [p for p in dirty if any(p == s or p.startswith(s.rstrip("/") + "/") for s in scopes)]

def is_mine(p):
    if p in owned: return True
    # git collapses a fully-untracked directory to "dir/" - it is mine if everything
    # this session wrote covers it, and foreign if I wrote nothing under it.
    if p.endswith("/") and any(o.startswith(p) for o in owned): return True
    return False

foreign = [p for p in dirty if not is_mine(p)]
if not foreign:
    if use_adopt:                     # consumed: an adopt unblocks one command, not an hour
        for f in (adopt, owner):
            try: os.remove(f)
            except Exception: pass
    raise SystemExit(0)

shown = "\n".join("  " + p for p in foreign[:8])
more  = "" if len(foreign) <= 8 else "\n  ...and %d more" % (len(foreign) - 8)
if mode == "destructive":
    head = ("DESTRUCTIVE COMMAND BLOCKED: this throws away uncommitted changes, and %d of the "
            "changes in this folder were NOT written by this session:" % len(foreign))
    body = ("Discarded work is not recoverable from git - it was never committed. If another "
            "Claude session is working in this same tree, this would delete its work outright.\n"
            "Do one of these, then tell the user in one line which:\n"
            "  1. Name only the paths this session changed: git restore <path> <path>\n"
            "  2. If every change listed above really is this session\x27s, run: "
            "bash .claude/memory-writer-lock.sh --adopt  - then retry (it unblocks ONE command).\n"
            "  3. If they belong to another session, leave them alone.")
else:
    head = ("BROAD-STAGING BLOCKED: this command stages every change in the folder, but %d of them "
            "were NOT written by this session:" % len(foreign))
    body = ("Another Claude session is probably working in this same working tree right now, and a "
            "broad `git add` / `git commit -a` sweeps its half-finished work into your commit - that "
            "is the exact incident this guard exists to stop.\n"
            "Do one of these, then tell the user in one line which:\n"
            "  1. Commit only the paths this session actually changed, by name (preferred):\n"
            "       git commit <path> <path> -m \"...\"\n"
            "  2. If every change listed above really is this session\x27s (a build or a script made "
            "them), run: bash .claude/memory-writer-lock.sh --adopt  - then retry (it unblocks ONE "
            "command).\n"
            "  3. If they belong to another session, leave them alone and commit your own paths only.")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                         "permissionDecision": "deny",
                                         "permissionDecisionReason": head + "\n" + shown + more + "\n" + body}}))
' "$LEDGERS" "$ADOPT" "$ADOPT_OWNER" "${SCOPE:-*}" "$MODE" "$ADOPT_SECS" "${SID:-}" "${TRANS:-}" 2>/dev/null
    # a deny was printed only if foreign work was found; either way we are done here
    exit 0
  fi
fi

# ---- CHECK 3: a plain path-scoped commit while another session is live -----
if [ "${ISCOMMIT:-0}" = "1" ] && [ -z "${GPATH:-}" ]; then
  # Skip the warning when this commit is aimed at a different repository entirely -
  # a notice about THIS project's lock is wrong for a commit that is not touching it.
  if [ "$FOREIGN_REPO" = "0" ] && [ -f "$LOCK" ] && [ "$mine" = "0" ] && [ "$holder_live" = "1" ]; then
    /usr/bin/python3 -c '
import json, sys
msg = ("SINGLE-WRITER WARNING: another Claude session claimed this project at %s and is still "
       "live in this SAME working tree, so its uncommitted work is sitting here right now. "
       "Commit only the paths this session actually changed (git commit <path> <path> -m ...). "
       "Do NOT use git commit -a, git add -A, git add . or git add <directory>/ - every one of "
       "them sweeps the other session half-finished work into your commit. Say in one line "
       "that you scoped the commit." % sys.argv[1])
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": msg}}))
' "${holder_when:-an earlier time}" 2>/dev/null
  fi
  record
  exit 0
fi

# ---- allowed. Claim if this was a shared-page write, and record what we touched ----
if [ -n "${GPATH:-}" ]; then
  if [ ! -f "$LOCK" ] || [ "$mine" = "1" ]; then
    claim
  elif [ "$holder_live" = "0" ]; then
    # Held, but the holder's transcript went cold -> that session is gone. Take over,
    # allow, and say so: a dead session may have left half-written notebook edits.
    claim
    /usr/bin/python3 -c '
import json
msg = ("NOTE: this session just took over the memory-notebook claim from an earlier session that "
       "ended without releasing it (its transcript has gone cold). Nothing is broken - but that "
       "session may have left half-finished notebook edits behind, so run git status and read "
       "what is already in memory/daily.md before you add to it.")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": msg}}))
' 2>/dev/null
  fi
fi
record
exit 0
