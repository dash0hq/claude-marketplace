#!/usr/bin/env bash
# Tests for hooks/sync.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SH="$SCRIPT_DIR/../hooks/sync.sh"

PASS=0; FAIL=0

ok() { printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
ko() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

assert_file()         { [ -f "$1" ] && ok "$2" || ko "$2 (missing: $1)"; }
assert_no_file()      { [ ! -f "$1" ] && ok "$2" || ko "$2 (should not exist: $1)"; }
assert_eq()           { [ "$1" = "$2" ] && ok "$3" || ko "$3 (got '$1', want '$2')"; }
assert_contains()     { echo "$1" | grep -qF "$2" && ok "$3" || ko "$3 (no '$2' in: $1)"; }
assert_not_contains() { ! echo "$1" | grep -qF "$2" && ok "$3" || ko "$3 ('$2' found in: $1)"; }

# ── helpers ───────────────────────────────────────────────────────────────────

make_project() {
  local dir; dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  git -C "$dir" commit -q --allow-empty -m "init"
  # gitignore added after initial commit so tests can track yaml files first
  printf '.env\n.env.*\n*.yaml\n*.yml\n*.log\n' > "$dir/.gitignore"
  git -C "$dir" add .gitignore
  git -C "$dir" commit -q -m "gitignore"
  echo "$dir"
}

make_worktree() {
  local project="$1" name="${2:-wt}"
  mkdir -p "$project/.claude/worktrees/$name"
  echo "$project/.claude/worktrees/$name"
}

# Run the hook with CWD set to the project root — mirrors how Claude Code fires hooks
run_hook() {
  local project="$1"; shift
  (cd "$project" && "$@" | bash "$SYNC_SH")
}

stdin_name() { printf '{"tool_name":"EnterWorktree","tool_input":{"name":"%s"},"tool_response":"ok"}' "$1"; }
stdin_path() { printf '{"tool_name":"EnterWorktree","tool_input":{"path":"%s"},"tool_response":"ok"}' "$1"; }
stdin_other() { printf '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":"ok"}'; }

# ── tests ─────────────────────────────────────────────────────────────────────

test_copies_env_via_name() {
  local p; p=$(make_project)
  local wt; wt=$(make_worktree "$p" "feat")
  printf 'SECRET=1\n' > "$p/.env"

  run_hook "$p" stdin_name "feat" > /dev/null

  assert_file "$wt/.env"                          "name: .env copied"
  assert_eq "$(cat "$wt/.env")" "SECRET=1"        "name: .env content correct"
  rm -rf "$p"
}

test_copies_env_via_path() {
  local p; p=$(make_project)
  local wt; wt=$(make_worktree "$p" "feat")
  printf 'SECRET=2\n' > "$p/.env"

  run_hook "$p" stdin_path "$wt" > /dev/null

  assert_file "$wt/.env"                          "path: .env copied"
  assert_eq "$(cat "$wt/.env")" "SECRET=2"        "path: .env content correct"
  rm -rf "$p"
}

test_copies_multiple_files() {
  local p; p=$(make_project)
  local wt; wt=$(make_worktree "$p" "multi")
  printf 'A=1\n'   > "$p/.env"
  printf 'A=2\n'   > "$p/.env.local"
  printf 'k: v\n'  > "$p/agents.yaml"
  printf 'k: v\n'  > "$p/config.yml"

  run_hook "$p" stdin_name "multi" > /dev/null

  assert_file "$wt/.env"         "multi: .env copied"
  assert_file "$wt/.env.local"   "multi: .env.local copied"
  assert_file "$wt/agents.yaml"  "multi: agents.yaml copied"
  assert_file "$wt/config.yml"   "multi: config.yml copied"
  rm -rf "$p"
}

test_skips_identical_file_silently() {
  local p; p=$(make_project)
  local wt; wt=$(make_worktree "$p" "same")
  printf 'X=1\n' > "$p/.env"
  cp "$p/.env" "$wt/.env"

  OUT=$(run_hook "$p" stdin_name "same")

  assert_not_contains "$OUT" "skipped"            "identical: no warning emitted"
  assert_eq "$(cat "$wt/.env")" "X=1"             "identical: file untouched"
  rm -rf "$p"
}

test_warns_and_does_not_overwrite_differing_file() {
  local p; p=$(make_project)
  local wt; wt=$(make_worktree "$p" "diff")
  printf 'X=1\n'        > "$p/.env"
  printf 'X=MODIFIED\n' > "$wt/.env"

  OUT=$(run_hook "$p" stdin_name "diff")

  assert_contains "$OUT" "skipped"                "diff: warning emitted"
  assert_eq "$(cat "$wt/.env")" "X=MODIFIED"      "diff: worktree file not overwritten"
  rm -rf "$p"
}

test_no_output_when_nothing_matches() {
  local p; p=$(make_project)
  local wt; wt=$(make_worktree "$p" "empty")
  printf 'stuff\n' > "$p/build.log"  # gitignored but not .env* or *.yaml

  OUT=$(run_hook "$p" stdin_name "empty")

  assert_eq "$OUT" ""                             "no match: empty output"
  rm -rf "$p"
}

test_does_not_copy_tracked_yaml() {
  local p; p=$(make_project)
  local wt; wt=$(make_worktree "$p" "tracked")

  # Commit a yaml *before* *.yaml is gitignored so git will accept it
  # Temporarily override gitignore, commit, restore
  printf 'k: v\n' > "$p/tracked.yaml"
  git -C "$p" add -f "$p/tracked.yaml"
  git -C "$p" commit -q -m "track yaml"

  # Now tracked.yaml is committed → git ls-files --others won't list it
  run_hook "$p" stdin_name "tracked" > /dev/null

  assert_no_file "$wt/tracked.yaml"               "tracked: committed yaml not copied"
  rm -rf "$p"
}

test_ignores_wrong_tool_name() {
  local p; p=$(make_project)
  local wt; wt=$(make_worktree "$p" "other")
  printf 'X=1\n' > "$p/.env"

  OUT=$(run_hook "$p" stdin_other)

  assert_no_file "$wt/.env"                       "wrong tool: nothing copied"
  assert_eq "$OUT" ""                             "wrong tool: empty output"
  rm -rf "$p"
}

# ── run ───────────────────────────────────────────────────────────────────────

test_copies_env_via_name
test_copies_env_via_path
test_copies_multiple_files
test_skips_identical_file_silently
test_warns_and_does_not_overwrite_differing_file
test_no_output_when_nothing_matches
test_does_not_copy_tracked_yaml
test_ignores_wrong_tool_name

echo ""
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
