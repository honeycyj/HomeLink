#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TASK_ROOT/script/signing_settings.sh"
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then echo "A fixed signing identity is required." >&2; exit 1; fi
TEST_DIR="$TASK_ROOT/.build/signing-probe"
mkdir -p "$TEST_DIR"
chmod 700 "$TEST_DIR"
ACCOUNT="$(uuidgen)"
PROBE="$TEST_DIR/KeychainSigningProbe"
cleanup() { "$PROBE" delete "$ACCOUNT" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun swiftc "$TASK_ROOT/Tests/KeychainSigningProbe.swift" -o "$PROBE"
codesign --force --sign "$SIGNING_IDENTITY" --identifier local.homelink.HomeLink.signing-probe "$PROBE"
codesign -d -r- "$PROBE" 2>&1 | /usr/bin/sed -n '/^designated =>/p' >"$TEST_DIR/first-requirement"
codesign -dvvv "$PROBE" 2>&1 | /usr/bin/sed -n '/^CDHash=/p' >"$TEST_DIR/first-signature"
"$PROBE" create "$ACCOUNT"
xcrun swiftc -D SECOND_BUILD "$TASK_ROOT/Tests/KeychainSigningProbe.swift" -o "$PROBE"
codesign --force --sign "$SIGNING_IDENTITY" --identifier local.homelink.HomeLink.signing-probe "$PROBE"
codesign -d -r- "$PROBE" 2>&1 | /usr/bin/sed -n '/^designated =>/p' >"$TEST_DIR/second-requirement"
codesign -dvvv "$PROBE" 2>&1 | /usr/bin/sed -n '/^CDHash=/p' >"$TEST_DIR/second-signature"
[[ -s "$TEST_DIR/first-requirement" && -s "$TEST_DIR/first-signature" && -s "$TEST_DIR/second-signature" ]]
cmp "$TEST_DIR/first-requirement" "$TEST_DIR/second-requirement"
if cmp -s "$TEST_DIR/first-signature" "$TEST_DIR/second-signature"; then
  echo 'Test invalid: the builds must have different code hashes.' >&2
  exit 1
fi
"$PROBE" read "$ACCOUNT"
echo 'PASS: changed code retained the same certificate-bound identity.'
