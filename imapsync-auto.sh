#!/usr/bin/env bash
# Sync all mailboxes listed in a CSV from host1 (source) to host2 (destination).
#
# Retries forever on transient failures (kill, network blip).
# Skips rows with empty passwords.
# Skips accounts that fail IMAP authentication (no retry) and reports them at the end.
#
# CSV columns: email,password_old,password_new
#   password_old = source (host1)
#   password_new = destination (host2)
#
# Usage:
#   cp accounts.example.csv accounts.csv   # fill passwords (gitignored)
#   export HOST1=old.mail.example.com
#   export HOST2=new.mail.example.com
#   ./imapsync-auto.sh
#
# Long runs (recommended):
#   tmux new -s mail-migrate
#   caffeinate -dims ./imapsync-auto.sh
#   # detach: Ctrl+b then d

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Required: set source/destination IMAP hosts via environment
HOST1="${HOST1:-}"
HOST2="${HOST2:-}"
CSV_FILE="${CSV_FILE:-${SCRIPT_DIR}/accounts.csv}"
WORKDIR="${WORKDIR:-${SCRIPT_DIR}}"
LOG="${WORKDIR}/sync-all.log"
AUTH_FAIL_LOG="${WORKDIR}/auth-failures.log"
RETRY_SLEEP="${RETRY_SLEEP:-60}"

if [[ -z "$HOST1" || -z "$HOST2" ]]; then
  echo "Set HOST1 (source) and HOST2 (destination) IMAP hosts, e.g.:" >&2
  echo "  export HOST1=old.mail.example.com" >&2
  echo "  export HOST2=new.mail.example.com" >&2
  exit 1
fi

# Emails that failed authentication (skip, no retry)
AUTH_FAILED_ACCOUNTS=()

mkdir -p "$WORKDIR"
: > "$AUTH_FAIL_LOG"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

# Write one-line password files for this account (chmod 600)
write_passfiles() {
  local pass_old="$1"
  local pass_new="$2"
  local f1="${WORKDIR}/pass1.current"
  local f2="${WORKDIR}/pass2.current"
  printf '%s\n' "$pass_old" > "$f1"
  printf '%s\n' "$pass_new" > "$f2"
  chmod 600 "$f1" "$f2"
  echo "$f1|$f2"
}

# Detect IMAP auth failures in imapsync output.
# Prints which host failed (host1 / host2 / both / unknown) to stdout; returns 0 if auth fail.
is_auth_failure() {
  local outfile="$1"
  local host1_fail=0
  local host2_fail=0

  if grep -Eiq \
    'AUTHENTICATIONFAILED|authentication failed|LOGIN failed|Login failure|Invalid credentials|NO \[AUTHENTICATIONFAILED\]|Can.?t login|Error login|BADLOGIN|AUTHENTICATE failed|auth.*fail|failure.*auth|Incorrect username or password|Invalid login|Login denied|AUTH failed|EXIT_AUTHENTICATION_FAILURE' \
    "$outfile"; then

    if grep -Eiq 'Host1.*AUTHENTICATIONFAILED|Host1.*authentication failed|Host1.*LOGIN failed|Host1.*Error login|Host1.*Invalid credentials|Host1.*BADLOGIN|Login failure on Host1|ERROR:.*Host1|can not authenticate to Host1|Host1.*NO AUTH|EXIT_AUTHENTICATION_FAILURE_USER1' "$outfile"; then
      host1_fail=1
    fi
    if grep -Eiq 'Host2.*AUTHENTICATIONFAILED|Host2.*authentication failed|Host2.*LOGIN failed|Host2.*Error login|Host2.*Invalid credentials|Host2.*BADLOGIN|Login failure on Host2|ERROR:.*Host2|can not authenticate to Host2|Host2.*NO AUTH|EXIT_AUTHENTICATION_FAILURE_USER2' "$outfile"; then
      host2_fail=1
    fi

    if [[ "$host1_fail" -eq 1 && "$host2_fail" -eq 1 ]]; then
      echo "both"
    elif [[ "$host1_fail" -eq 1 ]]; then
      echo "host1 ($HOST1)"
    elif [[ "$host2_fail" -eq 1 ]]; then
      echo "host2 ($HOST2)"
    else
      echo "unknown side"
    fi
    return 0
  fi
  return 1
}

sync_account() {
  local email="$1"
  local passfile1="$2"
  local passfile2="$3"
  local outfile="$4"

  imapsync \
    --host1 "$HOST1" \
    --user1 "$email" \
    --passfile1 "$passfile1" \
    --ssl1 \
    --host2 "$HOST2" \
    --user2 "$email" \
    --passfile2 "$passfile2" \
    --ssl2 \
    --nofoldersizes \
    --nofoldersizesatend \
    --useuid \
    --errorsmax 200 \
    2>&1 | tee "$outfile"
  return "${PIPESTATUS[0]}"
}

# Returns:
#   0 = synced OK
#   2 = auth failure (skip, do not retry)
sync_account_until_done() {
  local email="$1"
  local pass_old="$2"
  local pass_new="$3"
  local attempt=1
  local files passfile1 passfile2
  local outfile="${WORKDIR}/last-run.out"
  local rc side

  files=$(write_passfiles "$pass_old" "$pass_new")
  passfile1="${files%%|*}"
  passfile2="${files##*|}"

  log "=== START $email ==="
  while true; do
    log "$email attempt $attempt"
    sync_account "$email" "$passfile1" "$passfile2" "$outfile"
    rc=$?

    if [[ "$rc" -eq 0 ]]; then
      log "=== DONE $email ==="
      return 0
    fi

    if side=$(is_auth_failure "$outfile"); then
      log "SKIP AUTH $email — unauthenticated / login failed ($side)"
      echo "$(date '+%Y-%m-%d %H:%M:%S')  $email  side=$side" >> "$AUTH_FAIL_LOG"
      AUTH_FAILED_ACCOUNTS+=("$email [$side]")
      return 2
    fi

    log "$email stopped (exit $rc). Retry in ${RETRY_SLEEP}s..."
    attempt=$((attempt + 1))
    sleep "$RETRY_SLEEP"
  done
}

report_auth_failures() {
  echo
  log "========== AUTHENTICATION FAILURES =========="
  if [[ "${#AUTH_FAILED_ACCOUNTS[@]}" -eq 0 ]]; then
    log "None — all attempted accounts authenticated OK (or only empty-password skips)."
  else
    log "Skipped ${#AUTH_FAILED_ACCOUNTS[@]} account(s) due to auth errors:"
    local i=1
    local entry
    for entry in "${AUTH_FAILED_ACCOUNTS[@]}"; do
      log "  $i. $entry"
      i=$((i + 1))
    done
    log "Full list also in: $AUTH_FAIL_LOG"
  fi
  log "============================================="
}

process_csv() {
  local csv="$1"
  local line email pass_old pass_new
  local lineno=0

  log "--- Reading $(basename "$csv") ---"

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    [[ "$lineno" -eq 1 && "$line" =~ ^email, ]] && continue

    IFS=',' read -r email pass_old pass_new <<<"$line"
    email="${email// /}"
    pass_old="${pass_old#"${pass_old%%[![:space:]]*}"}"
    pass_old="${pass_old%"${pass_old##*[![:space:]]}"}"
    pass_new="${pass_new#"${pass_new%%[![:space:]]*}"}"
    pass_new="${pass_new%"${pass_new##*[![:space:]]}"}"

    if [[ -z "$email" ]]; then
      continue
    fi
    if [[ -z "$pass_old" || -z "$pass_new" ]]; then
      log "SKIP $email (password_old or password_new empty)"
      continue
    fi

    sync_account_until_done "$email" "$pass_old" "$pass_new" || true
  done < "$csv"
}

# --- main ---
if ! command -v imapsync >/dev/null 2>&1; then
  echo "imapsync not found. Install it first (e.g. brew install imapsync)."
  exit 1
fi

if [[ ! -f "$CSV_FILE" ]]; then
  echo "Missing CSV: $CSV_FILE"
  echo "Copy accounts.example.csv to accounts.csv and fill in passwords."
  exit 1
fi

log "########## Sync all mailboxes ##########"
log "CSV: $CSV_FILE"
log "Host1: $HOST1  Host2: $HOST2"

process_csv "$CSV_FILE"

rm -f "${WORKDIR}/pass1.current" "${WORKDIR}/pass2.current"

report_auth_failures

log "########## All CSV accounts finished ##########"
echo "Log: $LOG"
echo "Auth failures: $AUTH_FAIL_LOG"
if [[ "${#AUTH_FAILED_ACCOUNTS[@]}" -gt 0 ]]; then
  exit 2
fi
