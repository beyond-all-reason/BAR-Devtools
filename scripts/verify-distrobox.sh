#!/usr/bin/env bash
# Verify all tools inside the bar-dev distrobox are working.
# Usage: bash scripts/verify-distrobox.sh
set -euo pipefail

BOX="${DEVTOOLS_DISTROBOX:-bar-dev}"
PASS=0
FAIL=0

check() {
  local label="$1"; shift
  if output=$(distrobox enter "$BOX" -- bash -c "$*" 2>&1); then
    printf "  \033[32m✓\033[0m  %-14s %s\n" "$label" "$(echo "$output" | head -1)"
    PASS=$((PASS + 1))
  else
    printf "  \033[31m✗\033[0m  %-14s %s\n" "$label" "$(echo "$output" | tail -1)"
    FAIL=$((FAIL + 1))
  fi
}

echo "Checking distrobox '$BOX'..."
echo ""

check "lua"     "lua -v"
check "lx"      "lx --version"
check "node"    "node --version"
check "npm"     "npm --version"
check "cargo"   "cargo --version"
check "clangd"  "clangd --version 2>&1 | head -1"
check "stylua"  "stylua --version"
check "cmake"   "cmake --version | head -1"
check "git"     "git --version"
check "gcc"     "gcc --version | head -1"
check "g++"     "g++ --version | head -1"
check "make"    "make --version | head -1"
check "curl"    "curl --version | head -1"
check "jq"      "jq --version"

echo ""
echo "lx test (BAR unit tests)..."
if distrobox enter "$BOX" -- bash -c "cd ${BAR_DIR:-$PWD/Beyond-All-Reason} && lx --lua-version 5.1 test 2>&1" | tail -3; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m  lx test\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m  lx test\n"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
