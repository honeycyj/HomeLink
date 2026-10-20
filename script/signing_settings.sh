# Sourced by local build and signing checks; never stores certificate private keys.
SIGNING_IDENTITY="${HOMELINK_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && -f "$TASK_ROOT/Configuration/Local.xcconfig" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/awk -F= '/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=/ {value=$2; sub(/^[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value); print value; exit}' "$TASK_ROOT/Configuration/Local.xcconfig")"
fi
SIGNING_SETTINGS=()
if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]]; then
  if ! /usr/bin/security find-identity -p codesigning | /usr/bin/grep -Fq -- "$SIGNING_IDENTITY"; then
    echo 'The configured HomeLink signing identity is unavailable. Restore it before rebuilding; no silent ad-hoc fallback.' >&2
    exit 1
  fi
  SIGNING_SETTINGS+=("CODE_SIGN_IDENTITY=$SIGNING_IDENTITY" "CODE_SIGN_STYLE=Manual")
else
  SIGNING_SETTINGS+=("CODE_SIGN_IDENTITY=-")
  echo 'HomeLink: no fixed signing identity configured; rebuilding may require Keychain authorization again.' >&2
fi
