#!/bin/bash
# Dashboard generator + validator. Two modes:
#   bash .claude/memory-dashboard-check.sh --write   # regenerate the generated
#                                                     # panels from the notebook
#                                                     # and write them in.
#   bash .claude/memory-dashboard-check.sh           # validate only - read-only,
#                                                     # NEVER writes the file.
# Exit 0 = OK (validate: everything matches; --write: written cleanly).
# Exit 1 = refused: a source file is missing/unparseable, the status-data block
#          is missing/unparseable/missing an expected key (hand-customized
#          dashboard), or (validate only) a generated panel has drifted from
#          its notebook source. On ANY refusal --write changes nothing.
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
MODE="check"
[ "${1:-}" = "--write" ] && MODE="write"
/usr/bin/python3 - "$PROJ" "$MODE" <<'PY'
import sys, json, re, datetime, io, os
proj, mode = sys.argv[1], sys.argv[2]
def read(p):
    try: return io.open(p, encoding="utf-8").read()
    except Exception: return None
status_p = proj + "/project-status.html"
html = read(status_p)
ot   = read(proj + "/memory/open-threads.md")
idx  = read(proj + "/memory/index.md")
cur  = read(proj + "/memory/CURRENT.md")
dec  = read(proj + "/memory/decisions.md")
if html is None or ot is None or idx is None or dec is None:
    print("dashboard-check: missing project-status.html, open-threads.md, index.md, or decisions.md"); sys.exit(1)
m = re.search(r'(<script id="status-data" type="application/json">\s*)(\{.*?\})(\s*</script>)', html, re.S)
if not m:
    print("dashboard-check: no status-data JSON block found - nothing changed (looks like a hand-customized dashboard)"); sys.exit(1)
try: d = json.loads(m.group(2))
except Exception as e:
    print("dashboard-check: JSON does not parse: %s - nothing changed" % e); sys.exit(1)

# ---- shared text helpers: human-readable, markdown-stripped, word-truncated ----
def strip_md(s):
    s = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", s)  # [text](url) -> text
    s = s.replace("**", "").replace("`", "")          # drop bold + code ticks
    return re.sub(r"\s+", " ", s).strip()
def truncate(s, limit=160):
    s = s.strip()
    if len(s) <= limit: return s
    cut = s[:limit].rsplit(" ", 1)[0].rstrip(" ,;:-")
    return (cut or s[:limit]) + "..."
def section_body(text, heading):
    if text is None: return None
    sm = re.search(r'^## +' + heading + r'\s*$(.*?)(?=^## |\Z)', text, re.S | re.M)
    return sm.group(1) if sm else None
# Top-level '- ' bullets, each joined across its continuation lines - up to the
# next top-level bullet, a blank line, or a heading - the same whole-bullet
# capture the understanding deriver has always used (a bullet may wrap several
# physical lines). checkbox_only keeps only unchecked '- [ ] ' items, in order.
def top_items(body, checkbox_only=False):
    if body is None: return []
    lines = body.splitlines()
    items, i, n = [], 0, len(lines)
    while i < n:
        ln = lines[i]
        if ln.startswith("- "):
            parts = [ln]
            j = i + 1
            while j < n:
                nxt = lines[j]
                if not nxt.strip(): break
                if nxt.startswith("- "): break
                if re.match(r"^\s*#", nxt): break
                parts.append(nxt.strip())
                j += 1
            joined = " ".join(p.strip() for p in parts)
            if (not checkbox_only) or ln.startswith("- [ ] "):
                items.append(joined)
            i = j
        else:
            i += 1
    return items
# An open-threads bullet becomes its bold lead ("**lead:** detail..." -> "lead")
# or, lacking one, its first sentence - never the whole multi-line entry.
def lead_or_sentence(bullet):
    c = bullet[2:].strip() if bullet.startswith("- ") else bullet.strip()
    bm = re.match(r"^\*\*(.+?)\*\*", c)
    if bm:
        lead = bm.group(1)
    else:
        sm = re.search(r"^(.*?[.!?])(\s|$)", c)
        lead = sm.group(1) if sm else c
    return truncate(strip_md(lead).rstrip(" :;-"))
def objective_text(bullet):
    mo = re.match(r"^- \[ \]\s*(.*)$", bullet, re.S)
    return truncate(strip_md(mo.group(1) if mo else bullet))
# The understanding deriver: CURRENT.md's What/Where bullets (fallback: the
# index.md Snapshot, for a not-yet-migrated project). A label may carry a
# parenthetical - "**Status (2026-07-19):**" - handled the same as before.
def bullet_field(text, labels):
    if not text: return None
    lines = text.splitlines()
    pat = re.compile(r"^- \*\*(?:" + labels + r")[^:*]*:\*\*[ \t]*(.*)$")
    for i, ln in enumerate(lines):
        mm = pat.match(ln)
        if not mm: continue
        parts = [mm.group(1)]
        for cont in lines[i+1:]:
            if not cont.strip(): break
            if re.match(r"^\s*-\s", cont): break
            if re.match(r"^\s*#", cont): break
            parts.append(cont.strip())
        return strip_md(" ".join(p for p in parts if p.strip()))
    return None

src = cur if (cur and re.search(r'^- \*\*What[^:*]*:\*\*', cur, re.M)) else idx
snap = bullet_field(src, "What")
stat = bullet_field(src, "Where|Status")
understanding = truncate(snap + ((" " + stat) if stat else "")) if snap else None

known_body, ideas_body, quest_body = (section_body(ot, s) for s in ("Known issues", "Ideas", "Open questions"))
known = [lead_or_sentence(b) for b in top_items(known_body)] if known_body is not None else None
ideas = [lead_or_sentence(b) for b in top_items(ideas_body)] if ideas_body is not None else None
quest = [lead_or_sentence(b) for b in top_items(quest_body)] if quest_body is not None else None
if known is None or ideas is None:
    print("dashboard-check: open-threads.md is missing its 'Known issues' or 'Ideas' section"); sys.exit(1)
if quest is None:
    print("dashboard-check: open-threads.md is missing its 'Open questions' section - add the section (even if empty), then re-run"); sys.exit(1)

nn_body = section_body(cur, r"Now / Next") if cur else None
objectives = [objective_text(b) for b in top_items(nn_body, checkbox_only=True)] if nn_body is not None else None

dmatches = re.findall(r'^## \[(\d{4}-\d{2}-\d{2})\]\s*(.*)$', dec, re.M)
# decisions.md entries are always headed "## [YYYY-MM-DD] title" (the protocol's
# Decisions section spells out that exact format). A file with SOME level-2+ heading
# but none in that shape (e.g. "### 2026-07-01 -- title") means real entries exist in
# a style this parser cannot read - writing an empty array would silently wipe the
# panel. A file with NO heading at all (the fresh-install placeholder prose, or a
# truly empty file) has no decisions yet, so an empty panel is correct and must NOT
# be refused - that distinction (some heading vs. none) is what tells them apart.
if re.search(r'^#{2,6}\s+\S', dec, re.M) and not dmatches:
    print("dashboard-check: memory/decisions.md has heading(s) that do not match the expected "
          "'## [YYYY-MM-DD] title' format, so no decisions could be read from it - the "
          "decisions panel was left as-is, nothing changed. Fix the headings to that format "
          "(or edit project-status.html's decisions key by hand), then re-run."); sys.exit(1)
# Rulebook format (protocol 2026-08-06): decisions.md groups live rules by topic, so
# FILE order no longer means recency - sort by date before slicing (ISO dates sort
# lexically; Python's sort is stable, so same-day entries keep their file order).
# Harmless on an old diary-format file, where file order already was date order.
dmatches.sort(key=lambda t: t[0])
# The two-write contract's mechanical net: a rulebook file declares itself (detected by
# its H1 heading, not body prose - rename the heading to opt out), and every rule's DATE
# should have a full what/why entry that day in a memory/decisions-archive-*.md. The
# contract's actual promise is narrower than "counts match", though: it only guarantees a
# rule's date is LOOKABLE UP at all. Refuse-on-ZERO is that hard contract. Count SHORTFALL
# (some but fewer entries than rules on a date) is a soft signal only, never a refusal -
# a migration can legitimately split one decision into several rules on the same date
# (a pilot project: 11 rulebook rules / 9 archive entries on one real date, correctly so), and
# blocking on count equality was tried and reverted for the same reason title-strict
# matching was: it cried wolf on a shape the contract never promised to prevent.
# Matching is by date only, deliberately: titles get tightened when prose is compressed
# into a rule (the pilot project drifted on 22 of 28 titles while keeping every date).
# Diary-format files (no "rulebook" in the H1 heading) are exempt: their live entries
# predate the contract and never had archive copies.
first_line = dec.split("\n", 1)[0]
if "rulebook" in first_line.lower():
    import glob as _glob
    import collections as _collections
    arch = ""
    for ap in sorted(_glob.glob(proj + "/memory/decisions-archive-*.md")):
        arch += (read(ap) or "") + "\n"
    # Per-date counts drive both signals: ZERO entries on a rule's date is the hard
    # refusal (the date is not lookable up at all); SOME-but-fewer is a soft note only.
    rule_counts = _collections.Counter(dt for dt, _t in dmatches)
    archive_counts = _collections.Counter(re.findall(r'^## \[(\d{4}-\d{2}-\d{2})\]', arch, re.M))
    zero_dates = sorted(dt for dt, n in rule_counts.items() if archive_counts.get(dt, 0) == 0)
    short_dates = sorted(dt for dt, n in rule_counts.items() if 0 < archive_counts.get(dt, 0) < n)
    if short_dates:
        note_detail = "; ".join(
            "[%s] (%d rules, %d %s)" % (dt, rule_counts[dt], archive_counts.get(dt, 0),
                                        "entry" if archive_counts.get(dt, 0) == 1 else "entries")
            for dt in short_dates
        )
        print("dashboard-check note: fewer archive entries than rulebook rules on " + note_detail +
              " - fine if rules were split from one decision; otherwise backfill the missing prose.")
    if zero_dates:
        def _plural(n):
            return "y" if n == 1 else "ies"
        detail = "; ".join(
            "[%s] %d rule(s), %d archive entr%s" % (dt, rule_counts[dt], archive_counts.get(dt, 0), _plural(archive_counts.get(dt, 0)))
            for dt in zero_dates
        )
        print("dashboard-check: rulebook rule(s) with no matching archive entry (no entry dated "
              "the same day in memory/decisions-archive-*.md): " + detail + " - "
              "backfill the full what/why prose into the current month's archive, then re-run. "
              "Never fix this by deleting the rule."); sys.exit(1)
# {date, what} objects, not a flat "date - title" string - the template renderer
# expects x.date / x.what and shows literal "undefined" for every row otherwise.
decisions = [{"date": dt, "what": truncate(strip_md(title))} for dt, title in dmatches[-6:]]

# ---- sessions: recent entries from the working journal (opt-in, never validated) ----
# Source is the memory/daily/ shelf plus daily.md - exactly the pages compaction merges
# and clears - so this panel SHRINKS as the journal decays. That is honest: it is a view
# of recent activity, not an archive (history.md holds the day summaries after that, in a
# different shape, and is deliberately not read here). Heading shape is the protocol's:
# "## [YYYY-MM-DD - session <id>] title". Anything that does not match is skipped, never
# guessed at.
SESSION_HEAD = re.compile(r'^##\s*\[\s*(\d{4}-\d{2}-\d{2})\s*-\s*session\s+([^\]]+?)\s*\]\s*(.*)$', re.M)
jpaths = []
_ddir = proj + "/memory/daily"
if os.path.isdir(_ddir):
    jpaths = [_ddir + "/" + fn for fn in sorted(os.listdir(_ddir))
              if fn.endswith(".md") and fn != "README.md"]
jpaths.append(proj + "/memory/daily.md")
sessions, _seen = [], set()
for jp in jpaths:
    jtxt = read(jp)
    if not jtxt: continue
    for jdate, jsid, jtitle in SESSION_HEAD.findall(jtxt):
        jtitle = strip_md(jtitle).strip()
        key = (jdate, jsid, jtitle)
        if key in _seen: continue
        _seen.add(key)
        sessions.append({"date": jdate, "session": jsid, "title": truncate(jtitle) or "(untitled entry)"})
# newest first: reverse first so that WITHIN one date the later entry on the page leads,
# then a stable sort by date descending keeps that order intact
sessions.reverse()
sessions.sort(key=lambda x: x["date"], reverse=True)
sessions = sessions[:8]

if understanding is None:
    print("dashboard-check: neither CURRENT.md nor the index.md Snapshot has a '- **What:**' line to derive understanding from"); sys.exit(1)

# objectives has no fallback source - it is CURRENT.md's Now/Next, full stop. A
# project that predates CURRENT.md (understanding still derives from the index.md
# Snapshot) simply has nothing to derive objectives FROM - skip that one key rather
# than refusing the whole run over a section that was never there to begin with.
expected = {"understanding": understanding, "issues": known, "ideas": ideas, "questions": quest, "decisions": decisions}
if objectives is not None:
    expected["objectives"] = objectives

missing_keys = [k for k in expected if k not in d]
if missing_keys:
    print("dashboard-check: project-status.html's status-data block has no %s key(s) - looks like "
          "a hand-customized dashboard. Add the panel(s) by hand (or restore the stock keys) "
          "before this tool can check or generate them. Nothing was changed." % ", ".join(missing_keys))
    sys.exit(1)

if mode == "write":
    for k, v in expected.items():
        d[k] = v
    # opt-in: present means the dashboard renders it, absent means leave the block alone
    if "sessions" in d:
        d["sessions"] = sessions
    d["lastUpdated"] = datetime.date.today().isoformat()
    # The JSON lands INSIDE a <script> element, so a literal "</" in any generated
    # value (e.g. a bullet mentioning a closing script tag) would end the block
    # early and break the dashboard - silently. Escaping "</" as "<\/" is inert
    # to every JSON parser ("\/" IS "/") and cannot terminate a tag.
    payload = json.dumps(d, indent=2, ensure_ascii=True).replace("</", "<\\/")
    new = m.group(1) + payload + m.group(3)
    # Same-dir temp + atomic rename: a kill mid-write must never leave a truncated
    # dashboard (2026-08-04 audit - this file is one the product promises never to destroy).
    tmp_p = status_p + ".tmp"
    io.open(tmp_p, "w", encoding="utf-8").write(html[:m.start()] + new + html[m.end():])
    os.replace(tmp_p, status_p)
    counts = ", ".join("%s (%d)" % (k, len(v)) for k, v in expected.items() if isinstance(v, list))
    skipped = " (objectives skipped - CURRENT.md has no Now/Next section to derive from)" if objectives is None else ""
    sess_note = (" sessions (%d) refreshed from the journal." % len(sessions)) if "sessions" in d else ""
    print("dashboard-check --write: OK - regenerated understanding, %s, and lastUpdated.%s%s "
          "Roadmap and any custom key were left untouched." % (counts, skipped, sess_note))
    sys.exit(0)

# Validate mode: every generated panel must match its notebook source exactly
# (content, not just count) - roadmap is never checked, nothing generates it.
errs = []
for k in expected:
    if d.get(k) != expected[k]:
        actual = d.get(k)
        if isinstance(actual, list) and len(actual) != len(expected[k]):
            errs.append("%s panel has %d item(s) but the notebook has %d" % (k, len(actual), len(expected[k])))
        else:
            errs.append("%s panel does not match its notebook source" % k)
if errs:
    print("dashboard-check: MIRROR DRIFT - refusing.")
    for e in errs: print("  - " + e)
    print("Run: bash .claude/memory-dashboard-check.sh --write   (then re-run this check)")
    sys.exit(1)
counts = ", ".join("%s %d" % (k, len(v)) for k, v in expected.items() if isinstance(v, list))
print("dashboard-check: OK - %s, and understanding all match the notebook." % counts)
PY
