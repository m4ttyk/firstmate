#!/usr/bin/env bash
# fm-claude-disabled-plugins.sh - Claude Code plugins a home keeps off in the
# Claude sessions Firstmate launches.
#
# Usage:
#   bin/fm-claude-disabled-plugins.sh fragment <config-dir>
#   bin/fm-claude-disabled-plugins.sh json <config-dir>
#   bin/fm-claude-disabled-plugins.sh --help
#
# docs/claude-worker-plugins.md owns the operator contract; this header owns
# the mechanics.
#
# Source: <config-dir>/claude-worker-disabled-plugins, one plugin id per line
# in Claude Code's `<plugin>@<marketplace>` form. Blank lines and lines whose
# first non-blank character is `#` are ignored; surrounding blanks are trimmed.
#
#   fragment  prints `,"enabledPlugins":{"<id>":false,...}` with no newline,
#             for appending inside an existing settings JSON object.
#   json      prints `{"enabledPlugins":{"<id>":false,...}}` with no newline,
#             a complete --settings value.
#
# An absent file, or one with no ids, prints nothing and exits 0, so callers
# stay byte-identical to a launch without this feature. An id outside
# [A-Za-z0-9._-]+@[A-Za-z0-9._-]+ prints an error naming the file and line to
# stderr and exits 1 with no stdout; callers refuse the launch. The character
# set also keeps every id safe inside single-quoted shell and JSON strings.
set -u

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

build() {
  local file=$1/claude-worker-disabled-plugins line n=0 out=
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$line" in '' | '#'*) continue ;; esac
    if ! printf '%s' "$line" | grep -Eq '^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$'; then
      echo "error: $file line $n: '$line' is not a plugin id of the form <plugin>@<marketplace>" >&2
      return 1
    fi
    out="$out${out:+,}\"$line\":false"
  done <"$file"
  [ -z "$out" ] || printf '"enabledPlugins":{%s}' "$out"
}

case "${1:-}" in
  fragment | json)
    [ $# -eq 2 ] || { usage >&2; exit 2; }
    body=$(build "$2") || exit 1
    [ -n "$body" ] || exit 0
    if [ "$1" = fragment ]; then printf ',%s' "$body"; else printf '{%s}' "$body"; fi
    ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
