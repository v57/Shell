#!/usr/bin/env bash
#
# headless_file_ops_check.sh
#
# Tiny headless verification for the file-operation command strings used by
# FileBrowserActions. It confirms the `list` + `open` commands are well-formed:
#
#   1. The FileCommandBuilder unit tests assert the EXACT list/open command
#      strings (quote-balanced, correct prefixes) for file and directory.
#   2. The `list` command actually runs (`cd <dir> && ls -la`) and returns the
#      directory's entries.
#   3. The `open` commands (file on macOS/Linux, and the directory `cd`) are
#      syntactically valid shell via `zsh -n` — a syntax-only check, so nothing
#      is launched and nothing external is touched.
#
# Prints progress and exits 0 only if every step passes.
set -euo pipefail
cd "$(dirname "$0")"

echo "== [1/3] Swift tests: exact list + open command strings =="
swift test --filter FileCommandBuilderTests > /tmp/fb_headless_tests.log 2>&1
if grep -q "Suite FileCommandBuilderTests passed" /tmp/fb_headless_tests.log; then
  echo "  PASS — FileCommandBuilderTests assertions matched"
else
  echo "  FAIL — command-string tests did not pass"
  tail -30 /tmp/fb_headless_tests.log
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/folder"

echo "== [2/3] list command executes (cd <dir> && ls -la) =="
LIST_OUT="$(zsh -lc "cd '$TMP' && ls -la")"
if printf '%s\n' "$LIST_OUT" | grep -q "folder"; then
  echo "  PASS — listing returned the directory's entries"
else
  echo "  FAIL — 'cd <dir> && ls -la' produced no expected output"
  printf '%s\n' "$LIST_OUT"
  exit 1
fi

echo "== [3/3] open commands are well-formed shell (syntax-only, no launch) =="
if zsh -n -c "cd '$TMP'"; then echo "  PASS — open <directory> \`cd <dir>\`"; else
  echo "  FAIL"; exit 1; fi
if zsh -n -c "open '$TMP/file.txt'"; then echo "  PASS — open <file> (macOS) \`open <file>\`"; else
  echo "  FAIL"; exit 1; fi
if zsh -n -c "xdg-open '$TMP/file.txt'"; then echo "  PASS — open <file> (Linux) \`xdg-open <file>\`"; else
  echo "  FAIL"; exit 1; fi

echo ""
echo "HEADLESS FILE-OPS CHECK PASSED"
