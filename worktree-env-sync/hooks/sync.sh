#!/usr/bin/env bash
# Copies gitignored .env* and *.yaml/*.yml files from the main project into a new worktree.

INPUT=$(cat)
WORKTREE=""

# PostToolUse / EnterWorktree
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [ "$TOOL" = "EnterWorktree" ]; then
  # Entering an existing worktree: path is explicit
  WORKTREE=$(printf '%s' "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null || true)

  if [ -z "$WORKTREE" ]; then
    # New worktree: derive path from name
    WT_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null || true)
    if [ -n "$WT_NAME" ]; then
      ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
      [ -n "$ROOT" ] && WORKTREE="$ROOT/.claude/worktrees/$WT_NAME"
    fi
  fi

  # Last resort: parse path from tool_response text
  if [ -z "$WORKTREE" ]; then
    RESPONSE=$(printf '%s' "$INPUT" | jq -r '.tool_response // empty' 2>/dev/null || true)
    WORKTREE=$(printf '%s' "$RESPONSE" | grep -oE '[^ ]+\.claude/worktrees/[^ ]+' | head -1 || true)
  fi
fi

# WorktreeCreate event
if [ -z "$WORKTREE" ]; then
  WORKTREE=$(printf '%s' "$INPUT" | jq -r '.worktree_path // empty' 2>/dev/null || true)
fi

[ -z "$WORKTREE" ] && exit 0
[ ! -d "$WORKTREE" ] && exit 0

# Derive main project root: worktrees live at <root>/.claude/worktrees/<name>
if echo "$WORKTREE" | grep -q '/.claude/worktrees/'; then
  PROJECT_ROOT="${WORKTREE%%/.claude/worktrees/*}"
else
  # Non-standard path: use git to find the main (first) worktree
  PROJECT_ROOT=$(git -C "$WORKTREE" worktree list --porcelain 2>/dev/null | \
    head -1 | sed 's/^worktree //' || true)
fi

[ -z "$PROJECT_ROOT" ] && exit 0
[ ! -d "$PROJECT_ROOT" ] && exit 0
[ "$PROJECT_ROOT" = "$WORKTREE" ] && exit 0

# Find gitignored files matching .env* or *.yaml/*.yml
MATCHED=$(git -C "$PROJECT_ROOT" ls-files --others --ignored --exclude-standard 2>/dev/null | \
  grep -E '(^|/)\.env($|\.)|\.(ya?ml)$' || true)

[ -z "$MATCHED" ] && exit 0

COPIED=0
SKIPPED=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  src="$PROJECT_ROOT/$f"
  dst="$WORKTREE/$f"
  [ ! -f "$src" ] && continue
  if [ -f "$dst" ]; then
    # Skip if identical; warn if worktree version differs
    if cmp -s "$src" "$dst"; then
      SKIPPED=$((SKIPPED + 1))
    else
      echo "worktree-env-sync: skipped $f (worktree version differs from project root)"
    fi
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    COPIED=$((COPIED + 1))
  fi
done <<< "$MATCHED"

[ "$COPIED" -gt 0 ] && echo "Synced $COPIED config file(s) to worktree"
exit 0
