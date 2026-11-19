#!/usr/bin/env bash
# fm-overlay.sh - place a home's private repository overlay into a worker copy.
#
# Usage:
#   bin/fm-overlay.sh apply <data-dir> <project-dir> <worktree>
#   bin/fm-overlay.sh --help
#
# An overlay is a directory of agent-facing files that belong to work in one
# repository but are never committed to it: an AGENTS.md, rule documents,
# skills. docs/overlays.md owns the operator contract; this header owns the
# mechanics. bin/fm-spawn.sh calls `apply` once per ship or scout launch, fresh
# or relaunched, after the worker copy is asserted and before any harness starts.
#
# Source: <data-dir>/overlays/<name>/, where <name> is the basename of
# <project-dir> - the name data/projects.md and projects/ use. The overlay
# mirrors the repository layout, so every regular file and symbolic link lands
# at the same relative path in <worktree>. A symbolic link is copied as a link,
# never followed, and file modes are preserved.
#
# No overlay directory and no earlier placement: exit 0, no output, no writes.
#
# Hiding mechanism: each placed path gets one anchored entry in the git exclude
# file the copy reads (`git rev-parse --git-path info/exclude`), and placement
# is confirmed with `git check-ignore` first. No tracked file is modified and
# nothing outside that repository is written. Trade-offs, owned here:
#   - A linked worktree shares that file with every other copy of the same
#     repository, the primary checkout included, so an entry also hides a
#     same-named untracked file there.
#   - Entries are only ever appended. Removing one could expose a file this
#     script placed in a sibling copy as unlanded work and block that copy's
#     launch or cleanup, so a path withdrawn from the overlay stays ignored in
#     that repository until the operator edits the exclude file.
# Ignored files survive `git clean -fd` and `git status` reads, so cleanup's
# landed-work check and the pool-slot return never see them.
#
# Per-copy manifest: <git-dir>/fm-overlay-manifest lists the paths this script
# placed in that copy. It lives in the copy's own git directory, never in the
# work tree. The next apply uses it to refresh those paths to the current
# overlay content and to remove paths the overlay no longer carries, including
# when the whole overlay directory is gone.
#
# A path is skipped, with one `overlay: skipped <path>: <reason>` line on
# stderr, when placing it could replace or expose something that is not the
# overlay's own:
#   - the repository tracks the path (this version adds new files only);
#   - an untracked file or directory the overlay did not place is already
#     there with different content;
#   - a parent of the path is a symbolic link or a file in the copy;
#   - the repository's own ignore rules re-include the path, so it cannot be
#     hidden from git.
# A successful placement prints one `overlay: placed <n> path(s) from <dir>`
# line on stderr. stdout stays empty so the spawn's own output is unchanged.
#
# Exit 1, with `error: overlay: ...` on stderr, when the overlay cannot be
# applied as written: a copy or removal fails, the worker copy is not a git
# work tree, or the overlay holds a `.git` path component, a path containing a
# newline, or an entry that is neither a regular file, a directory, nor a
# symbolic link. The caller stops the launch rather than starting a worker
# without its instructions.
set -euo pipefail

MANIFEST_NAME=fm-overlay-manifest

usage() {
  sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

overlay_fail() {
  echo "error: overlay: $*" >&2
  exit 1
}

overlay_skip() { # <path> <reason>
  echo "overlay: skipped $1: $2" >&2
}

overlay_git() {
  git --literal-pathspecs -C "$WT" "$@"
}

overlay_tracked() { # <path>
  overlay_git ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

# A manifest line is trusted only as a path inside the copy.
overlay_path_is_contained() { # <path>
  case "/$1/" in
  *//* | */../* | */./*) return 1 ;;
  esac
  [ -n "$1" ]
}

# Sets OVERLAY_PARENT_REASON and returns 1 when a parent of <path> in the copy
# is anything other than a real directory or absent, so no write or removal
# ever follows a link out of the copy.
overlay_parents_are_directories() { # <path>
  local rest=$1 prefix='' part
  OVERLAY_PARENT_REASON=''
  while :; do
    case "$rest" in
    */*) ;;
    *) return 0 ;;
    esac
    part=${rest%%/*}
    rest=${rest#*/}
    prefix="${prefix:+$prefix/}$part"
    if [ -L "$WT/$prefix" ]; then
      OVERLAY_PARENT_REASON="its parent $prefix is a symbolic link in the copy"
      return 1
    fi
    if [ -e "$WT/$prefix" ] && [ ! -d "$WT/$prefix" ]; then
      OVERLAY_PARENT_REASON="its parent $prefix is a file in the copy"
      return 1
    fi
  done
}

overlay_same_content() { # <source> <destination>
  if [ -L "$1" ] || [ -L "$2" ]; then
    [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
    return
  fi
  [ -f "$2" ] && cmp -s -- "$1" "$2"
}

overlay_in_manifest() { # <path>
  [ -f "$MANIFEST" ] && grep -qxF -- "$1" "$MANIFEST"
}

# Anchored gitignore pattern matching exactly <path>.
overlay_exclude_pattern() { # <path>
  local path=$1 trailing=''
  path=${path//\\/\\\\}
  path=${path//\*/\\*}
  path=${path//\?/\\?}
  path=${path//\[/\\[}
  while [ "${path% }" != "$path" ]; do
    path=${path% }
    trailing="$trailing\\ "
  done
  printf '/%s%s\n' "$path" "$trailing"
}

overlay_exclude() { # <path>
  local pattern
  pattern=$(overlay_exclude_pattern "$1")
  if [ -z "$EXCLUDE_FILE" ]; then
    EXCLUDE_FILE=$(overlay_git rev-parse --git-path info/exclude) ||
      overlay_fail "cannot resolve the git exclude file for $WT"
    case "$EXCLUDE_FILE" in
    /*) ;;
    *) EXCLUDE_FILE="$WT/$EXCLUDE_FILE" ;;
    esac
    mkdir -p "$(dirname "$EXCLUDE_FILE")" ||
      overlay_fail "cannot create the directory of $EXCLUDE_FILE"
  fi
  if ! grep -qxF -- "$pattern" "$EXCLUDE_FILE" 2>/dev/null; then
    if [ -s "$EXCLUDE_FILE" ] && [ -n "$(tail -c 1 "$EXCLUDE_FILE")" ]; then
      echo >>"$EXCLUDE_FILE" || overlay_fail "cannot write $EXCLUDE_FILE"
    fi
    printf '%s\n' "$pattern" >>"$EXCLUDE_FILE" || overlay_fail "cannot write $EXCLUDE_FILE"
  fi
}

# Remove one path this script placed earlier, unless the copy no longer holds
# it as an untracked file or link of its own.
overlay_remove_placed() { # <path>
  local path=$1 dir
  overlay_path_is_contained "$path" || return 0
  overlay_parents_are_directories "$path" || return 0
  [ -L "$WT/$path" ] || [ -f "$WT/$path" ] || return 0
  ! overlay_tracked "$path" || return 0
  rm -f -- "$WT/$path" || overlay_fail "cannot remove withdrawn overlay path $path from $WT"
  dir=$path
  while :; do
    case "$dir" in
    */*) dir=${dir%/*} ;;
    *) break ;;
    esac
    rmdir -- "$WT/$dir" 2>/dev/null || break
  done
}

overlay_remove_withdrawn() {
  local path
  [ -f "$MANIFEST" ] || return 0
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    if [ -n "$SRC" ] && { [ -L "$SRC/$path" ] || [ -f "$SRC/$path" ]; }; then
      continue
    fi
    overlay_remove_placed "$path"
  done <"$MANIFEST"
}

overlay_place() { # <path>
  local path=$1 owned=0 ignored=0
  if ! overlay_parents_are_directories "$path"; then
    overlay_skip "$path" "$OVERLAY_PARENT_REASON"
    return 0
  fi
  if overlay_tracked "$path"; then
    overlay_skip "$path" "the repository tracks this path, and an overlay only adds new files"
    return 0
  fi
  ! overlay_in_manifest "$path" || owned=1
  if [ -d "$WT/$path" ] && [ ! -L "$WT/$path" ]; then
    overlay_skip "$path" "a directory the overlay did not place is already there"
    return 0
  fi
  if [ "$owned" = 0 ] && { [ -e "$WT/$path" ] || [ -L "$WT/$path" ]; } &&
    ! overlay_same_content "$SRC/$path" "$WT/$path"; then
    overlay_skip "$path" "an untracked file the overlay did not place is already there"
    return 0
  fi
  overlay_exclude "$path"
  # check-ignore reads its argument as a plain path and refuses pathspec magic,
  # so it runs without the literal-pathspec switch the other reads use.
  git -C "$WT" check-ignore -q -- "$path" 2>/dev/null || ignored=$?
  if [ "$ignored" -ne 0 ]; then
    [ "$owned" = 0 ] || overlay_remove_placed "$path"
    if [ "$ignored" -eq 1 ]; then
      overlay_skip "$path" "the repository's ignore rules re-include it, so it cannot be hidden from git"
    else
      overlay_skip "$path" "git could not confirm that it is hidden"
    fi
    return 0
  fi
  case "$path" in
  */*) mkdir -p -- "$WT/${path%/*}" || overlay_fail "cannot create the directory of $path in $WT" ;;
  esac
  rm -f -- "$WT/$path" || overlay_fail "cannot replace $path in $WT"
  cp -P -p -- "$SRC/$path" "$WT/$path" || overlay_fail "cannot copy $path into $WT"
  printf '%s\n' "$path" >>"$MANIFEST_NEW" || overlay_fail "cannot record $path in $MANIFEST_NEW"
  PLACED=$((PLACED + 1))
}

overlay_apply() { # <data-dir> <project-dir> <worktree>
  local data=$1 project=$2 git_dir unsupported listing path
  WT=$3
  SRC="$data/overlays/$(basename "$project")"
  EXCLUDE_FILE=''
  PLACED=0

  if [ ! -d "$SRC" ]; then
    # Nothing to place. Only a copy that still carries an earlier placement
    # needs work: the overlay was withdrawn, so its files are withdrawn too.
    SRC=''
    git_dir=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null) || return 0
    MANIFEST="$git_dir/$MANIFEST_NAME"
    [ -f "$MANIFEST" ] || return 0
    overlay_remove_withdrawn
    rm -f -- "$MANIFEST" || overlay_fail "cannot remove $MANIFEST"
    return 0
  fi

  [ -d "$WT" ] || overlay_fail "worker copy $WT is not a directory, so $SRC cannot be placed"
  [ "$(git -C "$WT" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] ||
    overlay_fail "worker copy $WT is not a git work tree, so $SRC cannot be kept out of its commits"
  git_dir=$(git -C "$WT" rev-parse --absolute-git-dir) ||
    overlay_fail "cannot resolve the git directory of $WT"
  MANIFEST="$git_dir/$MANIFEST_NAME"
  MANIFEST_NEW="$MANIFEST.new"

  unsupported=$(find "$SRC/." -name '*
*' -print) || overlay_fail "cannot read $SRC"
  [ -z "$unsupported" ] || overlay_fail "$SRC holds a path containing a newline"
  unsupported=$(find "$SRC/." ! -type f ! -type d ! -type l -print) ||
    overlay_fail "cannot read $SRC"
  if [ -n "$unsupported" ]; then
    unsupported=${unsupported%%
*}
    overlay_fail "$SRC holds an entry that is not a regular file, directory, or symbolic link: ${unsupported#"$SRC/./"}"
  fi
  listing=$(find "$SRC/." \( -type f -o -type l \) -print | LC_ALL=C sort) ||
    overlay_fail "cannot list $SRC"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path=${path#"$SRC/./"}
    case "/$path/" in
    */.git/*) overlay_fail "$SRC holds a .git path, which an overlay must not carry: $path" ;;
    esac
  done <<EOF
$listing
EOF

  overlay_remove_withdrawn
  : >"$MANIFEST_NEW" || overlay_fail "cannot write $MANIFEST_NEW"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    overlay_place "${path#"$SRC/./"}"
  done <<EOF
$listing
EOF

  if [ -s "$MANIFEST_NEW" ]; then
    mv -f -- "$MANIFEST_NEW" "$MANIFEST" || overlay_fail "cannot write $MANIFEST"
  else
    rm -f -- "$MANIFEST_NEW" "$MANIFEST" || overlay_fail "cannot remove $MANIFEST"
  fi
  [ "$PLACED" -eq 0 ] || echo "overlay: placed $PLACED path(s) from $SRC" >&2
}

case "${1:-}" in
-h | --help)
  usage
  ;;
apply)
  [ "$#" -eq 4 ] || {
    echo "usage: fm-overlay.sh apply <data-dir> <project-dir> <worktree>" >&2
    exit 2
  }
  overlay_apply "$2" "$3" "$4"
  ;;
*)
  echo "usage: fm-overlay.sh apply <data-dir> <project-dir> <worktree>" >&2
  exit 2
  ;;
esac
