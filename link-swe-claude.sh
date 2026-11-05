#!/usr/bin/env bash
# link-swe-claude.sh - symlink swe-claude's Claude scaffolding into another project.
#
# Usage: link-swe-claude.sh [-n] [-c FILE] TARGET_DIR
#   -n        dry run: report what would happen, change nothing
#   -c FILE   link this directory's FILE (default CLAUDE.md) as TARGET_DIR/CLAUDE.md,
#             e.g. -c CLAUDE-bes.md
#
# Links .claude, ai-docs, ai-plans and CLAUDE.md from this directory into TARGET_DIR:
#   ai-docs, ai-plans  if TARGET_DIR already has one that isn't ours, report it and
#                      leave it alone
#   .claude            if TARGET_DIR already has one, report it and leave it alone
#   CLAUDE.md          an existing CLAUDE.md is moved to CLAUDE.md.orig first; one that
#                      already links to a different CLAUDE file here is re-pointed
# Links made by older versions of this script (docs or ai-docs -> $SRC/docs, and
# the same for plans) are removed and replaced by the ai-docs / ai-plans links.
# If TARGET_DIR is in a git work tree, the new names are added to that repo's
# .git/info/exclude so they never show up in 'git status', and the entries for
# removed docs / plans links are taken out.
# Safe to re-run: links that already point here are left as they are.
# Exit status is 1 if anything could not be linked (e.g. the project has its own .claude).
#
# Written for bash 3.2 (macOS) and later.

set -u

prog=$(basename "$0")
SRC=$(cd "$(dirname "$0")" && pwd -P)

usage() { echo "usage: $prog [-n] [-c FILE] TARGET_DIR" >&2; exit 2; }
say()   { printf '%s\n' "$*"; }
warn()  { printf '%s: %s\n' "$prog" "$*" >&2; }
run()   { if [ "$dry_run" -eq 1 ]; then say "  (dry run) $*"; else "$@"; fi; }

# exists PATH: true for files, dirs, and symlinks (including broken ones)
exists() { [ -e "$1" ] || [ -L "$1" ]; }

# is_our_link PATH NAME: true if PATH is a symlink to $SRC/NAME
is_our_link() { [ -L "$1" ] && [ "$(readlink "$1")" = "$SRC/$2" ]; }

# is_swe_link PATH: true if PATH is a symlink to anything in $SRC
is_swe_link() { [ -L "$1" ] && case $(readlink "$1") in "$SRC"/*) true ;; *) false ;; esac; }

dry_run=0
claude_md=CLAUDE.md
while getopts nc: opt; do
    case $opt in
        n) dry_run=1 ;;
        c) claude_md=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage

case $claude_md in
    */*|"") warn "-c takes a file name in $SRC, not a path: $claude_md"; exit 1 ;;
esac
[ -f "$SRC/$claude_md" ] || { warn "no such file in $SRC: $claude_md"; exit 1; }

TARGET=$(cd "$1" 2>/dev/null && pwd -P) || { warn "not a directory: $1"; exit 1; }
[ "$TARGET" != "$SRC" ] || { warn "target is swe-claude itself"; exit 1; }

say "Linking $SRC into $TARGET"

excludes=""        # space-separated names to add to .git/info/exclude
stale_excludes=""  # names of removed old links to take out of .git/info/exclude
removed=""         # names of old links removed (matters only in a dry run)
status=0

# make_link NAME DEST: link $SRC/NAME as $TARGET/DEST
make_link() {
    local name=$1 dest=$2 path="$TARGET/$2"
    if is_our_link "$path" "$name"; then
        say "ok:   $dest already links to $SRC/$name"
    elif exists "$path"; then
        warn "$dest already exists in $TARGET; not linking $name"
        status=1
        return 1
    else
        say "link: $dest -> $SRC/$name"
        run ln -s "$SRC/$name" "$path" || { status=1; return 1; }
    fi
    excludes="$excludes $dest"
}

in_git=0
git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1

is_tracked() {
    [ "$in_git" -eq 1 ] && git -C "$TARGET" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

# .claude: never renamed; an existing one is reported and left alone.
if exists "$TARGET/.claude" && ! is_our_link "$TARGET/.claude" .claude; then
    warn ".claude already exists in $TARGET; leaving it alone (swe-claude's .claude is NOT linked)"
    status=1
else
    make_link .claude .claude
fi

# Remove links made by older versions of this script, when swe-claude's
# directories were docs and plans (linked as docs/plans or ai-docs/ai-plans).
for old in docs plans; do
    for dest in "$old" "ai-$old"; do
        is_our_link "$TARGET/$dest" "$old" || continue
        say "remove: $dest (old link to $SRC/$old)"
        if run rm "$TARGET/$dest"; then
            removed="$removed $dest"
            [ "$dest" = "$old" ] && stale_excludes="$stale_excludes $dest"
        else
            status=1
        fi
    done
done

for name in ai-docs ai-plans; do
    case " $removed " in *" $name "*) was_removed=1 ;; *) was_removed=0 ;; esac
    if [ "$dry_run" -eq 1 ] && [ "$was_removed" -eq 1 ]; then   # nothing really removed, so don't re-check
        say "link: $name -> $SRC/$name"
        excludes="$excludes $name"
    else
        make_link "$name" "$name"
    fi
done

# CLAUDE.md: re-point a link to another of our CLAUDE files, or move an
# existing file aside, then link.
c="$TARGET/CLAUDE.md"
if is_swe_link "$c" && ! is_our_link "$c" "$claude_md"; then
    say "relink: CLAUDE.md was -> $(readlink "$c")"
    if run rm "$c"; then
        if [ "$dry_run" -eq 1 ]; then          # nothing really removed, so don't re-check
            say "link: CLAUDE.md -> $SRC/$claude_md"
            excludes="$excludes CLAUDE.md"
        else
            make_link "$claude_md" CLAUDE.md
        fi
    else
        status=1
    fi
elif exists "$c" && ! is_our_link "$c" "$claude_md"; then
    if exists "$c.orig"; then
        warn "CLAUDE.md and CLAUDE.md.orig both exist in $TARGET; leaving both alone (CLAUDE.md NOT linked)"
        status=1
    else
        if is_tracked CLAUDE.md; then
            warn "CLAUDE.md is tracked by git in $TARGET; git will now report it as changed"
            warn "  to hide that locally: git -C '$TARGET' update-index --skip-worktree CLAUDE.md"
        fi
        say "move: CLAUDE.md -> CLAUDE.md.orig"
        if run mv "$c" "$c.orig"; then
            excludes="$excludes CLAUDE.md.orig"
            if [ "$dry_run" -eq 1 ]; then      # nothing really moved, so don't re-check
                say "link: CLAUDE.md -> $SRC/$claude_md"
                excludes="$excludes CLAUDE.md"
            else
                make_link "$claude_md" CLAUDE.md
            fi
        else
            status=1
        fi
    fi
else
    make_link "$claude_md" CLAUDE.md
fi

# Keep the links out of the project's git status.
if [ "$in_git" -eq 1 ] && [ -n "$excludes$stale_excludes" ]; then
    ex=$(git -C "$TARGET" rev-parse --git-path info/exclude)
    case $ex in /*) ;; *) ex="$TARGET/$ex" ;; esac
    prefix=$(git -C "$TARGET" rev-parse --show-prefix)
    for name in $stale_excludes; do
        pat="/$prefix$name"
        grep -qxF "$pat" "$ex" 2>/dev/null || continue
        say "git:  remove $pat from $ex"
        if [ "$dry_run" -eq 0 ]; then
            { grep -vxF "$pat" "$ex" > "$ex.tmp.$$"; [ $? -le 1 ]; } &&
                mv "$ex.tmp.$$" "$ex" || { rm -f "$ex.tmp.$$"; status=1; }
        fi
    done
    for name in $excludes; do
        is_tracked "$name" && continue          # excluding a tracked path does nothing
        # No trailing slash: git sees a symlink as a file, not a directory.
        pat="/$prefix$name"
        grep -qxF "$pat" "$ex" 2>/dev/null && continue
        say "git:  add $pat to $ex"
        if [ "$dry_run" -eq 0 ]; then
            mkdir -p "$(dirname "$ex")" && printf '%s\n' "$pat" >> "$ex"
        fi
    done
fi

exit $status
