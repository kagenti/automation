#!/usr/bin/env bash
set -euo pipefail

# Test harness for parse-diff-map.sh
# Run: bash automation/tests/test-parse-diff-map.sh
# Exit code 0 = all tests pass, 1 = at least one failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/../scripts/parse-diff-map.sh"
TMPDIR=$(mktemp -d "/tmp/test-parse-diff-XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

# --- Helper: run a named test ---
run_test() {
  local name="$1"
  local diff_file="$2"
  local jq_check="$3"
  local expected="$4"

  local output
  output=$("$PARSER" "$diff_file")
  local actual
  actual=$(echo "$output" | jq -r "$jq_check")

  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    Expected: $expected"
    echo "    Got:      $actual"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 1: Empty file produces empty array ---
echo "Test 1: Empty input"
touch "$TMPDIR/empty.diff"
run_test "empty file returns []" "$TMPDIR/empty.diff" '.' '[]'

# --- Test 2: Single file with one hunk, added lines only ---
echo "Test 2: Single added file"
cat > "$TMPDIR/added.diff" << 'EOF'
diff --git a/new-file.txt b/new-file.txt
new file mode 100644
index 0000000..1234567
--- /dev/null
+++ b/new-file.txt
@@ -0,0 +1,3 @@
+line one
+line two
+line three
EOF

run_test "file count" "$TMPDIR/added.diff" 'length' '1'
run_test "file path" "$TMPDIR/added.diff" '.[0].path' 'new-file.txt'
run_test "hunk count" "$TMPDIR/added.diff" '.[0].hunks | length' '1'
run_test "line count" "$TMPDIR/added.diff" '.[0].hunks[0].lines | length' '3'
run_test "first line number" "$TMPDIR/added.diff" '.[0].hunks[0].lines[0].line' '1'
run_test "first line side" "$TMPDIR/added.diff" '.[0].hunks[0].lines[0].side' 'RIGHT'
run_test "first line type" "$TMPDIR/added.diff" '.[0].hunks[0].lines[0].type' 'added'
run_test "first line content" "$TMPDIR/added.diff" '.[0].hunks[0].lines[0].content' 'line one'
run_test "third line number" "$TMPDIR/added.diff" '.[0].hunks[0].lines[2].line' '3'

# --- Test 3: Removed lines get LEFT side with correct old line numbers ---
echo "Test 3: Removed lines"
cat > "$TMPDIR/removed.diff" << 'EOF'
diff --git a/file.txt b/file.txt
index 1234567..abcdef0 100644
--- a/file.txt
+++ b/file.txt
@@ -5,3 +5,1 @@
-old line five
-old line six
 kept line seven
EOF

run_test "removed line count" "$TMPDIR/removed.diff" '[.[0].hunks[0].lines[] | select(.type == "removed")] | length' '2'
run_test "removed line 1 number" "$TMPDIR/removed.diff" '.[0].hunks[0].lines[0].line' '5'
run_test "removed line 1 side" "$TMPDIR/removed.diff" '.[0].hunks[0].lines[0].side' 'LEFT'
run_test "removed line 2 number" "$TMPDIR/removed.diff" '.[0].hunks[0].lines[1].line' '6'
run_test "context line number" "$TMPDIR/removed.diff" '.[0].hunks[0].lines[2].line' '5'
run_test "context line side" "$TMPDIR/removed.diff" '.[0].hunks[0].lines[2].side' 'RIGHT'
run_test "context line type" "$TMPDIR/removed.diff" '.[0].hunks[0].lines[2].type' 'context'

# --- Test 4: Multiple hunks in a single file ---
echo "Test 4: Multiple hunks"
cat > "$TMPDIR/multi-hunk.diff" << 'EOF'
diff --git a/multi.txt b/multi.txt
index 1234567..abcdef0 100644
--- a/multi.txt
+++ b/multi.txt
@@ -1,3 +1,4 @@
 context A
+added after A
 context B
 context C
@@ -20,3 +21,2 @@
 context at 20
-removed at 21
 context at 22
EOF

run_test "two hunks" "$TMPDIR/multi-hunk.diff" '.[0].hunks | length' '2'
run_test "hunk 1 added line" "$TMPDIR/multi-hunk.diff" '.[0].hunks[0].lines[1].line' '2'
run_test "hunk 1 added type" "$TMPDIR/multi-hunk.diff" '.[0].hunks[0].lines[1].type' 'added'
run_test "hunk 2 removed line" "$TMPDIR/multi-hunk.diff" '.[0].hunks[1].lines[1].line' '21'
run_test "hunk 2 removed side" "$TMPDIR/multi-hunk.diff" '.[0].hunks[1].lines[1].side' 'LEFT'

# --- Test 5: Multiple files in one diff ---
echo "Test 5: Multiple files"
cat > "$TMPDIR/multi-file.diff" << 'EOF'
diff --git a/first.txt b/first.txt
index 1234567..abcdef0 100644
--- a/first.txt
+++ b/first.txt
@@ -1,2 +1,3 @@
 existing
+new in first
 more existing
diff --git a/second.txt b/second.txt
index 1234567..abcdef0 100644
--- a/second.txt
+++ b/second.txt
@@ -10,2 +10,3 @@
 ten
+eleven added
 twelve
EOF

run_test "two files" "$TMPDIR/multi-file.diff" 'length' '2'
run_test "first file path" "$TMPDIR/multi-file.diff" '.[0].path' 'first.txt'
run_test "second file path" "$TMPDIR/multi-file.diff" '.[1].path' 'second.txt'
run_test "second file line number" "$TMPDIR/multi-file.diff" '.[1].hunks[0].lines[1].line' '11'

# --- Test 6: Special characters in content (quotes, backslashes, tabs) ---
echo "Test 6: Special characters"
cat > "$TMPDIR/special.diff" << 'EOF'
diff --git a/special.txt b/special.txt
index 1234567..abcdef0 100644
--- a/special.txt
+++ b/special.txt
@@ -1,1 +1,3 @@
 normal line
+line with "quotes" and a \backslash
+	tab-indented line
EOF

run_test "quotes escaped" "$TMPDIR/special.diff" '.[0].hunks[0].lines[1].content | contains("quotes")' 'true'
run_test "backslash escaped" "$TMPDIR/special.diff" '.[0].hunks[0].lines[1].content | contains("\\")' 'true'

# --- Test 7: stdin input ---
echo "Test 7: Stdin input"
STDIN_OUTPUT=$(cat "$TMPDIR/added.diff" | "$PARSER" -)
STDIN_COUNT=$(echo "$STDIN_OUTPUT" | jq 'length')
if [ "$STDIN_COUNT" = "1" ]; then
  echo "  PASS: stdin input works"
  PASS=$((PASS + 1))
else
  echo "  FAIL: stdin input (expected 1 file, got $STDIN_COUNT)"
  FAIL=$((FAIL + 1))
fi

# --- Test 8: Valid JSON output (parse without error) ---
echo "Test 8: Output is valid JSON"
if echo "$STDIN_OUTPUT" | jq empty 2>/dev/null; then
  echo "  PASS: output is valid JSON"
  PASS=$((PASS + 1))
else
  echo "  FAIL: output is not valid JSON"
  FAIL=$((FAIL + 1))
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
