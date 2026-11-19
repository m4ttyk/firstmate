# Repository overlays

An overlay is a set of agent-facing files that applies to work in one repository but is never committed to it.
Typical contents are an `AGENTS.md`, rule documents, and skills: anything that gives workers context for that repository without becoming part of its history.
Firstmate places a project's overlay into every worker copy of that project.

Overlays are a fork-carried feature; [`CARRY.md`](../CARRY.md) lists the files it adds to upstream Firstmate.

## Where an overlay lives

Each project's overlay is the directory `data/overlays/<project>/` inside the Firstmate home.
`<project>` is the project's directory name, the same name `data/projects.md` and `projects/` use.
`data/` is private, gitignored home state, so an overlay never enters Firstmate's own history either.

The overlay mirrors the repository layout.
Every file lands at the same relative path in the worker copy:

```text
data/overlays/demo-project/
  AGENTS.md
  CLAUDE.md -> AGENTS.md
  .agents/skills/demo-skill/SKILL.md
  docs/rules/reviews.md
```

A worker in `demo-project` then finds `AGENTS.md`, `CLAUDE.md`, the skill, and the rule document at those paths in its own copy.

## What Firstmate does with it

- Firstmate places the overlay each time it launches a ship or scout worker for the project, including a relaunch, before the worker starts.
- A symbolic link is placed as a symbolic link, and file modes are preserved.
- Placed files are hidden from git in that repository, so they never show in the worker's `git status` and `git add -A` does not stage them.
- Each launch refreshes the placed files to the overlay's current content and removes files the overlay no longer carries, so editing or deleting a file under `data/overlays/<project>/` reaches the next launch.
- A project with no overlay directory launches exactly as it did before.
- Cleanup does not treat overlay files as unlanded work.

## Limits

- An overlay only adds new files.
  A path the repository already tracks is skipped, and the launch prints one line naming it.
- A path is also skipped, with one line naming it, when an untracked file the overlay did not place is already there, when a parent of the path is a symbolic link or a file in the worker copy, or when the repository's own ignore rules re-include the path.
- An overlay that cannot be applied as written stops the launch instead of starting a worker without its instructions.
  That covers a failed copy and an overlay holding a `.git` path or a special file.
- The hiding entries live in the repository's git exclude file, which every copy of that repository shares, the primary checkout included.
  They are never removed automatically, so a path withdrawn from an overlay stays ignored in that repository until the entry is deleted by hand.
- Keep files Firstmate itself writes into a worker copy, such as `.claude/settings.local.json` or `CLAUDE.local.md`, out of an overlay.
  Firstmate rewrites, refuses, or removes those per task.
- Secondmate homes do not receive overlays.

[`bin/fm-overlay.sh`](../bin/fm-overlay.sh)'s header owns the exact mechanics, and [`tests/fm-overlay.test.sh`](../tests/fm-overlay.test.sh) is the verification entry point.
