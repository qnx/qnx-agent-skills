#!/bin/sh
# Link this repo's skills into a global agent skills directory.
#
# Only needed if your client reads skills from a global location rather than
# from the project directory. If you run your agent from inside this repo, the
# committed symlinks (.claude/skills, .codex/skills, .agents/skills) already
# point at skills/ and there is nothing to do.
#
# Usage: ./setup.sh [claude|codex|agents]
#        defaults to "agents" (the cross-client convention)

set -eu

CLIENT="${1:-agents}"
REPO="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO/skills"

case "$CLIENT" in
  claude) DEST="$HOME/.claude/skills" ;;
  codex)  DEST="$HOME/.codex/skills" ;;
  agents) DEST="$HOME/.agents/skills" ;;
  *) echo "unknown client '$CLIENT' (expected: claude, codex, agents)" >&2; exit 1 ;;
esac

if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
  echo "refusing to replace existing directory: $DEST" >&2
  echo "move it aside first, or link skills individually." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
rm -f "$DEST"
ln -s "$SRC" "$DEST"
echo "linked $DEST -> $SRC"
echo "skills available: $(ls "$SRC" | wc -l)"
