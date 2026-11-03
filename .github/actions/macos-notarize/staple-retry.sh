#!/usr/bin/env bash
# Staple and validate a notarization ticket, retrying Apple-side transients.
#
# Usage: staple-retry.sh <bundle>
#
# Each attempt runs `xcrun stapler staple` then `xcrun stapler validate`, so a
# validate that reports no ticket is followed by a fresh staple on the next
# attempt. Only transient failures are retried: exit code 68, or output
# matching a known CloudKit / network pattern, or "no ticket" from validate.
# Anything else fails at once. After the last attempt it fails with the last
# error. Every attempt is printed.
#
# Test hooks: STAPLER (default "xcrun stapler"), STAPLE_SLEEPS (space
# separated seconds between attempts, default "10 20 40 60"; its length + 1 is
# the attempt count).
set -uo pipefail

bundle="${1:?usage: staple-retry.sh <bundle>}"
stapler="${STAPLER:-xcrun stapler}"
read -r -a sleeps <<< "${STAPLE_SLEEPS:-10 20 40 60}"
max=$(( ${#sleeps[@]} + 1 ))

transient_re='NSURLErrorDomain|network connection was lost|CloudKit.s response is inconsistent|apple-cloudkit\.com|could not connect to the server|request timed out|timed out|temporarily unavailable'
noticket_re='does not have a ticket stapled|no ticket|could not find (base64 encoded )?ticket'

# run <label> <subcommand>: sets $rc and $out.
run() {
  out="$($stapler "$1" "$bundle" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  echo "stapler $1 exit $rc"
}

is_transient() {
  [ "$rc" -eq 68 ] || printf '%s' "$out" | grep -Eiq "$transient_re"
}

attempt=1
while :; do
  echo "--- staple/validate attempt $attempt of $max ---"
  failed=""
  run staple
  if [ "$rc" -ne 0 ]; then
    failed=staple
  else
    run validate
    [ "$rc" -ne 0 ] && failed=validate
  fi
  if [ -z "$failed" ]; then
    echo "staple validated on attempt $attempt"
    exit 0
  fi
  retry=0
  if is_transient; then retry=1; fi
  if [ "$failed" = validate ] && printf '%s' "$out" | grep -Eiq "$noticket_re"; then retry=1; fi
  if [ "$retry" -ne 1 ]; then
    echo "::error::stapler $failed failed (exit $rc) with a non-transient error; not retrying"
    exit "$rc"
  fi
  if [ "$attempt" -ge "$max" ]; then
    echo "::error::stapler $failed still failing after $max attempts (last exit $rc); last error is above"
    exit "$rc"
  fi
  wait_s="${sleeps[$((attempt - 1))]}"
  echo "::warning::stapler $failed failed (exit $rc), transient; retrying in ${wait_s}s"
  sleep "$wait_s"
  attempt=$((attempt + 1))
done
