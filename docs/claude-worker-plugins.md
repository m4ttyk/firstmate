# Claude worker plugins

A home can keep chosen Claude Code plugins off in every Claude session Firstmate launches, while they stay on in the captain's own interactive sessions.
This suits plugins built for a person at the keyboard, such as status-bar hooks or a forced output style, which only cost tokens in headless and worker sessions.

Disabling worker plugins is a fork-carried feature; [`CARRY.md`](../CARRY.md) lists the files it adds to upstream Firstmate.

## The file

The optional, gitignored `config/claude-worker-disabled-plugins` lists one plugin id per line, in Claude Code's `<plugin>@<marketplace>` form:

```text
# interactive-only plugins
demo-tools@demo-market
```

Blank lines and `#` comments are ignored.
An absent file, or one with no ids, leaves every launch unchanged.

## What Firstmate does with it

- Each listed id is added as `"enabledPlugins": {"<id>": false}` to the `--settings` Firstmate already passes, so the plugin does not load at all, including any output style it forces.
- This covers ship and scout workers, secondmates, and the supervision host's headless engine; the captain's own session is never launched by Firstmate and is unaffected.
- An id that is not of the `<plugin>@<marketplace>` form is refused with the file and line, and the launch stops rather than run with the plugin on.
- A primary home pushes the file to its secondmates like its other inherited config, so their own workers disable the same plugins.
- The file affects Claude Code launches only; other worker runtimes ignore it.

[`bin/fm-claude-disabled-plugins.sh`](../bin/fm-claude-disabled-plugins.sh) owns the mechanics.
