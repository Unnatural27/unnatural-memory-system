# Unnatural Memory System

A persistent, plain-markdown memory for a Claude Code project. One script installs it; everything
it creates lives in your project's own repo and travels with git - no accounts, no server, no
database.

## Install

```bash
bash install-memory-system.sh "/path/to/your/project"
```

(Leave the path off to install into the folder you are currently in.) Then open the project in
Claude Code - that's it, there is nothing else to configure.

## What it creates

```
your-project/
  CLAUDE.md                          the rulebook Claude reads every session
  PROJECT.md                         how this project works - a blank frame you fill in
  GAPS.md                            where it's structurally weak - worst first
  memory/
    index.md                         the catalog - read first each session
    CURRENT.md                       present state + the Now/Next to-do list
    daily.md, daily/                 the working journal (one page per session)
    decisions.md                     the rulebook (full prose in dated archives)
    history.md                       medium-term archive
    open-threads.md                  known issues, ideas, open questions
    lessons.md                       how this project works better
    knowledge/
      reference/                    docs you drop in, kept raw
      research/                     dated research reports Claude writes
      topics/                       distilled, cited takeaways
  project-status.html                a viewable dashboard - double-click it
  pages/
    user-guide.html                 teaches the habit, self-updating
  .claude/
    memory-catchup.sh               SessionStart: backfills a forgotten session
    memory-commit-sync.sh           PostToolUse: keeps memory fresh after a commit
    memory-writer-lock.sh           holds the notebook to one writer at a time
    memory-dashboard-check.sh       validates the dashboard against the notebook
    skills/close-out/               the end-of-session checklist skill
```

The knowledge base splits by source: `memory/knowledge/reference/` keeps docs you drop in (raw),
`memory/knowledge/research/` keeps dated research reports Claude writes (raw, with sources), and
`memory/knowledge/topics/` holds the distilled, cited takeaways future decisions actually consult.

Existing files are never overwritten - only the installer-owned pieces (the four `.claude/*.sh`
scripts and `pages/user-guide.html`) are rewritten on every install, so a hand-customized `CLAUDE.md`
or notebook page always survives a re-install.

## Check your version / upgrade

```bash
bash install-memory-system.sh /path/to/project --version   # what this copy of the script is
grep memory-protocol CLAUDE.md                              # what protocol version a project is on
```

To bring an older project's protocol prose up to date without touching anything else:

```bash
bash install-memory-system.sh "/path/to/project" --upgrade-protocol
```

`--upgrade-protocol` replaces the versioned "Memory protocol" block in `CLAUDE.md` and nothing
else. It never rewrites a hook you have hand-customized, and it never touches `memory/` or
`project-status.html`. A project's own added rules survive the upgrade only if you wrapped them in
`<!-- project-custom:start -->` / `<!-- project-custom:end -->` markers inside the block; anything
else you added inside the block is replaced without warning, which is why the installer never
touches content outside the block at all.

## Verify it yourself

```bash
bash test-installer.sh
```

This is the real test harness the installer ships with - it builds throwaway test projects, installs
into them, and checks the result. As of this release it runs **576 checks** (that number is
this repo's own `bash test-installer.sh` output, read fresh, not a guess) and all of them must pass
before any change ships.

## Requirements

- **macOS** - this is what has actually been tested.
- Linux fallbacks exist in the scripts (`sed -i`, `stat -c`) but have never been exercised on a real
  Linux machine - treat that as untested, not supported.
- [Claude Code](https://claude.com/claude-code).
- `git` is recommended (the whole point is that your memory travels with your commits) but the
  installer itself does not require it to run.
- Bash + the system `/usr/bin/python3` that ships with macOS. No `pip`, no `npm`, no accounts, no
  network access of any kind.

## The one warning that matters

**The notebook is committed to git.** Everything Claude writes to `memory/` becomes part of your
project's history the moment you commit. Never let secrets, credentials, or anything you would not
want in a commit end up in there.

## Uninstall

One command:

```bash
bash install-memory-system.sh "/path/to/your/project" --uninstall
```

It removes the four `.claude/memory-*.sh` scripts, their hook entries in
`.claude/settings.json` (surgically - any other hooks and settings you have survive
byte-for-byte), the close-out skill, and the installer-owned `pages/user-guide.html`. It
never touches your `memory/` notebook, `project-status.html`, `CLAUDE.md`, or your own
pages - that data is yours, and the command ends by printing exactly what it removed and
what it left (including how to hand-delete the protocol block from `CLAUDE.md` if you want
that gone too). Leftover state under `~/.claude/tmp/` (`memory-*`, `commit-sync-*`) is
harmless and self-expires. Re-installing later picks the notebook up where it left off.

## License

MIT - see [LICENSE](LICENSE). Copyright (c) 2026 Unnatural Projects.

Version: UMS 1.6, protocol 2026-08-14.
