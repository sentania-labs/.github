#!/usr/bin/env bash
#
# Unit tests for tag-to-release action logic.
# Runs locally or in CI without making real GitHub API requests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SH="$SCRIPT_DIR/release.sh"

TEST_TMP="$(mktemp -d /tmp/tag-to-release-test-XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

MOCK_BIN="$TEST_TMP/mock_bin"
mkdir -p "$MOCK_BIN"
MOCK_GH="$MOCK_BIN/gh"
CALL_LOG="$TEST_TMP/gh_calls.log"

export PATH="$MOCK_BIN:$PATH"

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  [PASS] $desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $desc"
    echo "         expected: $expected"
    echo "         actual:   $actual"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_match() {
  local desc="$1"
  local regex="$2"
  local text="$3"
  if [[ "$text" =~ $regex ]]; then
    echo "  [PASS] $desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $desc: '$text' did not match pattern '$regex'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# Generate configurable mock gh
create_mock_gh() {
  local existing_releases="${1:-}"
  local existing_refs="${2:-}"
  
  cat > "$MOCK_GH" <<EOF
#!/usr/bin/env bash
set -eu
echo "gh \$*" >> "$CALL_LOG"

cmd="\$1"
shift

case "\$cmd" in
  repo)
    if [ "\${1:-}" = "view" ]; then
      echo "sentania-labs/test-repo"
      exit 0
    fi
    ;;
  release)
    sub="\${1:-}"
    shift
    case "\$sub" in
      view)
        tag="\$1"
        for ex in $existing_releases; do
          if [ "\$tag" = "\$ex" ]; then
            echo '{"id":"123456","url":"https://github.com/sentania-labs/test-repo/releases/tag/'"\$tag"'","isPrerelease":false,"isLatest":false}'
            exit 0
          fi
        done
        echo "release not found" >&2
        exit 1
        ;;
      list)
        echo "[$existing_releases]" >&2
        # print releases as tagName lines if jq used
        for ex in $existing_releases; do
          echo "\$ex"
        done
        exit 0
        ;;
      create)
        tag="\$1"
        echo "https://github.com/sentania-labs/test-repo/releases/tag/\$tag"
        exit 0
        ;;
    esac
    ;;
  api)
    endpoint="\$1"
    if [[ "\$endpoint" == *"git/matching-refs/tags/v"* ]]; then
      for r in $existing_refs; do
        echo "refs/tags/\$r"
      done
      exit 0
    fi
    ;;
esac

echo "mock gh: unhandled command \$cmd \$*" >&2
exit 1
EOF
  chmod +x "$MOCK_GH"
}

# --- Test 1: Refuse invalid tags ---
echo "=== Test 1: Refuse invalid tags ==="
for bad_tag in "1.2.3" "v1.2" "v1.2.3.4" "main" "latest" "v01.2.3" "release-1.0"; do
  set +e
  out=$(GITHUB_REPOSITORY="sentania-labs/test-repo" GH_TOKEN="dummy" TAG="$bad_tag" bash "$RELEASE_SH" 2>&1)
  rc=$?
  set -e
  assert_eq "Rejects invalid tag '$bad_tag' with exit code 1" "1" "$rc"
  assert_match "Output contains non-version tag refusal" "is not a valid vMAJOR\.MINOR\.PATCH tag" "$out"
done

# --- Test 2: Missing GH_TOKEN fails ---
echo "=== Test 2: Missing GH_TOKEN fails ==="
set +e
out=$(GITHUB_REPOSITORY="sentania-labs/test-repo" GH_TOKEN="" TAG="v1.0.0" bash "$RELEASE_SH" 2>&1)
rc=$?
set -e
assert_eq "Fails without token" "1" "$rc"
assert_match "Output mentions GH_TOKEN missing" "GH_TOKEN / github-token is missing" "$out"

# --- Test 3: Idempotent when release already exists ---
echo "=== Test 3: Idempotency check ==="
create_mock_gh "v1.0.0" ""
: > "$CALL_LOG"
out_file="$TEST_TMP/gh_out_3"
: > "$out_file"

set +e
out=$(GITHUB_REPOSITORY="sentania-labs/test-repo" GH_TOKEN="dummy" TAG="v1.0.0" GITHUB_OUTPUT="$out_file" bash "$RELEASE_SH" 2>&1)
rc=$?
set -e
assert_eq "Succeeds (rc 0) when release already exists" "0" "$rc"
assert_match "Output logs idempotency skip" "already exists in .* skipping creation \(idempotent\)" "$out"
outputs=$(cat "$out_file")
assert_match "GITHUB_OUTPUT created=false" "created=false" "$outputs"
assert_match "GITHUB_OUTPUT url matches" "url=https://github.com/sentania-labs/test-repo/releases/tag/v1.0.0" "$outputs"
assert_match "GITHUB_OUTPUT id matches" "id=123456" "$outputs"

# Confirm gh release create was NEVER called
set +e
grep -q "gh release create" "$CALL_LOG"
create_called=$?
set -e
assert_eq "gh release create was NOT called" "1" "$create_called"

# --- Test 4: Highest version marked latest ---
echo "=== Test 4: Highest version marked latest ==="
create_mock_gh "v1.0.0 v1.1.0" "v1.0.0 v1.1.0"
: > "$CALL_LOG"
out_file="$TEST_TMP/gh_out_4"
: > "$out_file"

out=$(GITHUB_REPOSITORY="sentania-labs/test-repo" GH_TOKEN="dummy" TAG="v1.2.0" GITHUB_OUTPUT="$out_file" bash "$RELEASE_SH" 2>&1)
assert_match "Output identifies as highest version" "'?v1.2.0'? is the highest version; marking as latest" "$out"
calls=$(cat "$CALL_LOG")
assert_match "Calls gh release create with --latest" "gh release create v1.2.0 .* --latest" "$calls"
outputs=$(cat "$out_file")
assert_match "GITHUB_OUTPUT is-latest=true" "is-latest=true" "$outputs"
assert_match "GITHUB_OUTPUT is-prerelease=false" "is-prerelease=false" "$outputs"
assert_match "GITHUB_OUTPUT created=true" "created=true" "$outputs"

# --- Test 5: Lower version (backport patch) NOT marked latest ---
echo "=== Test 5: Lower version backport patch NOT marked latest ==="
create_mock_gh "v1.0.0 v2.0.0" "v1.0.0 v2.0.0"
: > "$CALL_LOG"
out_file="$TEST_TMP/gh_out_5"
: > "$out_file"

out=$(GITHUB_REPOSITORY="sentania-labs/test-repo" GH_TOKEN="dummy" TAG="v1.0.1" GITHUB_OUTPUT="$out_file" bash "$RELEASE_SH" 2>&1)
assert_match "Output identifies higher version exists" "found higher version 'v2.0.0'; not marking 'v1.0.1' as latest" "$out"
calls=$(cat "$CALL_LOG")
assert_match "Calls gh release create with --latest=false" "gh release create v1.0.1 .* --latest=false" "$calls"
outputs=$(cat "$out_file")
assert_match "GITHUB_OUTPUT is-latest=false" "is-latest=false" "$outputs"

# --- Test 6: Pre-release suffix detected and never marked latest ---
echo "=== Test 6: Pre-release suffix ==="
create_mock_gh "v1.0.0" "v1.0.0"
: > "$CALL_LOG"
out_file="$TEST_TMP/gh_out_6"
: > "$out_file"

out=$(GITHUB_REPOSITORY="sentania-labs/test-repo" GH_TOKEN="dummy" TAG="v2.0.0-rc.1" GITHUB_OUTPUT="$out_file" bash "$RELEASE_SH" 2>&1)
assert_match "Output identifies prerelease" "'?v2.0.0-rc.1'? is a pre-release; not marking as latest" "$out"
calls=$(cat "$CALL_LOG")
assert_match "Calls gh release create with --prerelease and --latest=false" "gh release create v2.0.0-rc.1 .* --prerelease --latest=false" "$calls"
outputs=$(cat "$out_file")
assert_match "GITHUB_OUTPUT is-prerelease=true" "is-prerelease=true" "$outputs"
assert_match "GITHUB_OUTPUT is-latest=false" "is-latest=false" "$outputs"

# --- Test 7: Files attachment and glob expansion ---
echo "=== Test 7: File attachments ==="
create_mock_gh "" ""
: > "$CALL_LOG"
asset_dir="$TEST_TMP/assets"
mkdir -p "$asset_dir"
echo "binary content" > "$asset_dir/app-linux-amd64.tar.gz"
echo "checksum" > "$asset_dir/app-linux-amd64.sha256"

out=$(GITHUB_REPOSITORY="sentania-labs/test-repo" GH_TOKEN="dummy" TAG="v0.4.2" FILES="$asset_dir/*.tar.gz
$asset_dir/*.sha256
$asset_dir/missing.file" bash "$RELEASE_SH" 2>&1)
calls=$(cat "$CALL_LOG")
assert_match "Includes tar.gz asset" "$asset_dir/app-linux-amd64.tar.gz" "$calls"
assert_match "Includes sha256 asset" "$asset_dir/app-linux-amd64.sha256" "$calls"
assert_match "Warns about missing file pattern" "no regular file matches pattern.*missing.file" "$out"

# --- Test 8: Notes start tag and draft flags ---
echo "=== Test 8: Notes start tag and draft flags ==="
create_mock_gh "" ""
: > "$CALL_LOG"
out=$(GITHUB_REPOSITORY="sentania-labs/test-repo" GH_TOKEN="dummy" TAG="v1.0.0" NOTES_START_TAG="v0.9.0" DRAFT="true" bash "$RELEASE_SH" 2>&1)
calls=$(cat "$CALL_LOG")
assert_match "Includes --notes-start-tag" "--notes-start-tag v0.9.0" "$calls"
assert_match "Includes --draft" "--draft" "$calls"

echo "=============================="
echo "Tests completed: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
