#!/usr/bin/env bash
#
# Create a GitHub Release for a version tag using gh release create.
# Standardized release action for sentania-labs.
#
# Requirements satisfied:
# 1. Idempotent: if a release for the tag already exists, succeeds without mutation.
# 2. Strict tag format: refuses anything not matching vMAJOR.MINOR.PATCH (SemVer 2.0).
# 3. Pre-release suffix: automatically marked pre-release when tag contains a pre-release suffix (e.g. -rc.1).
# 4. Highest version: marks "latest" only when the tag is the highest version among existing stable tags/releases.
# 5. Minimal inputs with sensible defaults: files, notes-start-tag, draft, prerelease, latest, title.
# 6. Runs on plain bash + gh, compatible with lab runners and GitHub-hosted runners without Docker.

set -euo pipefail

# Helper to write to GITHUB_OUTPUT if set
set_output() {
  local key="$1"
  local val="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "${key}=${val}" >> "$GITHUB_OUTPUT"
  fi
}

# Determine repository
REPO="${GITHUB_REPOSITORY:-}"
if [ -z "$REPO" ]; then
  # Try resolving via gh or git if outside GitHub Actions
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
if [ -z "$REPO" ]; then
  echo "::error::tag-to-release: unable to determine repository. Set GITHUB_REPOSITORY or run in a repository context."
  exit 1
fi

# Check authentication token
if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::tag-to-release: GH_TOKEN / github-token is missing or empty. Ensure 'permissions: contents: write' is set on the calling job."
  exit 1
fi
export GH_TOKEN

# Normalize tag
TAG="${TAG:-${GITHUB_REF_NAME:-}}"
TAG="${TAG#refs/tags/}"

if [ -z "$TAG" ]; then
  echo "::error::tag-to-release: no tag provided and GITHUB_REF_NAME is empty."
  exit 1
fi

# Validate tag: MUST be vMAJOR.MINOR.PATCH according to SemVer 2.0 with leading 'v'.
# Individual dot-separated identifiers in pre-release must be non-empty; numeric
# pre-release identifiers must not have leading zeros. Build metadata identifiers
# must be non-empty alphanumeric/hyphen.
pr_id="0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*"
b_id="[0-9A-Za-z-]+"
semver_regex="^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(($pr_id)(\.($pr_id))*))?(\+($b_id(\.$b_id)*))?$"
if [[ ! "$TAG" =~ $semver_regex ]]; then
  echo "::error::tag-to-release: '$TAG' is not a valid vMAJOR.MINOR.PATCH tag (e.g. v1.2.3, v0.4.2, v1.0.0-rc.1). Non-version tags are refused."
  exit 1
fi

cur_maj="${BASH_REMATCH[1]}"
cur_min="${BASH_REMATCH[2]}"
cur_pat="${BASH_REMATCH[3]}"
cur_pre="${BASH_REMATCH[4]}"

# Check if release already exists (idempotency requirement)
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "tag-to-release: release for '$TAG' already exists in $REPO; skipping creation (idempotent)."
  # gh release view supports: apiUrl, assets, author, body, createdAt, databaseId, id, isDraft,
  # isImmutable, isPrerelease, name, publishedAt, tagName, tarballUrl, targetCommitish, uploadUrl, url, zipballUrl.
  # (isLatest is NOT a field on gh release view; query supported fields and do not suppress errors).
  rel_json="$(gh release view "$TAG" --repo "$REPO" --json id,url,isPrerelease)"
  rel_id="$(echo "$rel_json" | jq -r '.id // ""')"
  rel_url="$(echo "$rel_json" | jq -r '.url // ""')"
  is_pre="$(echo "$rel_json" | jq -r '.isPrerelease // false')"

  # Determine if this existing release is currently the latest release
  latest_tag=""
  if latest_json="$(gh release view --repo "$REPO" --json tagName 2>/dev/null)"; then
    latest_tag="$(echo "$latest_json" | jq -r '.tagName // empty' 2>/dev/null || true)"
  fi
  if [ -z "$latest_tag" ]; then
    if latest_api="$(gh api "repos/$REPO/releases/latest" 2>/dev/null)"; then
      latest_tag="$(echo "$latest_api" | jq -r '.tag_name // empty' 2>/dev/null || true)"
    fi
  fi

  is_lat="false"
  if [ -n "$latest_tag" ] && [ "$latest_tag" = "$TAG" ]; then
    is_lat="true"
  fi

  set_output "created" "false"
  set_output "id" "$rel_id"
  set_output "url" "$rel_url"
  set_output "tag" "$TAG"
  set_output "is-prerelease" "$is_pre"
  set_output "is-latest" "$is_lat"
  exit 0
fi

# Determine pre-release status
PRERELEASE="${PRERELEASE:-auto}"
is_prerelease="false"
case "$PRERELEASE" in
  true)
    is_prerelease="true"
    ;;
  false)
    is_prerelease="false"
    ;;
  auto)
    if [ -n "$cur_pre" ]; then
      is_prerelease="true"
    fi
    ;;
  *)
    echo "::warning::tag-to-release: invalid prerelease option '$PRERELEASE', defaulting to auto"
    if [ -n "$cur_pre" ]; then
      is_prerelease="true"
    fi
    ;;
esac

# Determine latest status
LATEST="${LATEST:-auto}"
is_latest="false"
case "$LATEST" in
  true)
    is_latest="true"
    ;;
  false)
    is_latest="false"
    ;;
  auto)
    if [ "$is_prerelease" = "true" ]; then
      # Pre-releases are never marked latest
      is_latest="false"
      echo "tag-to-release: '$TAG' is a pre-release; not marking as latest."
    else
      # Check against all existing tags and releases in the repo
      is_latest="true"
      higher_found=""

      # 1. Fetch remote tags starting with 'v'
      tags_rc=0
      existing_tags="$(gh api "repos/$REPO/git/matching-refs/tags/v" --paginate --jq '.[].ref' 2>/dev/null | sed 's|^refs/tags/||')" || tags_rc=$?

      # 2. Fetch existing published releases
      releases_rc=0
      existing_releases="$(gh release list --repo "$REPO" --limit 1000 --exclude-drafts --exclude-pre-releases --json tagName --jq '.[].tagName' 2>/dev/null)" || releases_rc=$?

      # If both discovery requests fail, fail closed: do not mark latest to avoid promoting backports
      if [ "$tags_rc" -ne 0 ] && [ "$releases_rc" -ne 0 ]; then
        echo "::warning::tag-to-release: failed to discover existing tags and releases from $REPO; failing closed (not marking '$TAG' as latest)."
        is_latest="false"
      else
        all_other_tags="$(printf "%s\n%s\n" "$existing_tags" "$existing_releases" | sort -u)"

        stable_regex="^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\+($b_id(\.$b_id)*))?$"
        while IFS= read -r otag; do
          [ -z "$otag" ] && continue
          [ "$otag" = "$TAG" ] && continue
          if [[ "$otag" =~ $stable_regex ]]; then
            o_maj="${BASH_REMATCH[1]}"
            o_min="${BASH_REMATCH[2]}"
            o_pat="${BASH_REMATCH[3]}"
            if (( 10#$o_maj > 10#$cur_maj )) || \
               (( 10#$o_maj == 10#$cur_maj && 10#$o_min > 10#$cur_min )) || \
               (( 10#$o_maj == 10#$cur_maj && 10#$o_min == 10#$cur_min && 10#$o_pat > 10#$cur_pat )); then
              is_latest="false"
              higher_found="$otag"
              break
            fi
          fi
        done <<< "$all_other_tags"

        if [ "$is_latest" = "true" ]; then
          echo "tag-to-release: '$TAG' is the highest version; marking as latest."
        else
          echo "tag-to-release: found higher version '$higher_found'; not marking '$TAG' as latest."
        fi
      fi
    fi
    ;;
  *)
    echo "::warning::tag-to-release: invalid latest option '$LATEST', defaulting to false"
    is_latest="false"
    ;;
esac

# Resolve files to attach (if any)
assets=()
if [ -n "${FILES:-}" ]; then
  shopt -s nullglob
  while IFS= read -r pattern; do
    pattern="${pattern#"${pattern%%[![:space:]]*}"}" # trim leading
    pattern="${pattern%"${pattern##*[![:space:]]}"}" # trim trailing
    [ -z "$pattern" ] && continue
    matched=0
    for f in $pattern; do
      if [ -f "$f" ]; then
        assets+=("$f")
        matched=1
      fi
    done
    if [ "$matched" -eq 0 ]; then
      echo "::warning::tag-to-release: no regular file matches pattern '$pattern'"
    fi
  done <<< "$FILES"
  shopt -u nullglob
fi

# Dry run: report the decision and stop before anything is created
if [ "${DRY_RUN:-false}" = "true" ]; then
  echo "tag-to-release: dry-run: would create release for $TAG in $REPO (prerelease=$is_prerelease, latest=$is_latest, draft=${DRAFT:-false}, assets=${#assets[@]}); nothing created."
  set_output "created" "false"
  set_output "id" ""
  set_output "url" ""
  set_output "tag" "$TAG"
  set_output "is-prerelease" "$is_prerelease"
  set_output "is-latest" "$is_latest"
  exit 0
fi

# Build gh release create command
cmd=(gh release create "$TAG" --repo "$REPO" --verify-tag --generate-notes)

if [ "$is_prerelease" = "true" ]; then
  cmd+=(--prerelease)
fi

if [ "$is_latest" = "true" ]; then
  cmd+=(--latest)
else
  cmd+=(--latest=false)
fi

if [ "${DRAFT:-false}" = "true" ]; then
  cmd+=(--draft)
fi

if [ -n "${NOTES_START_TAG:-}" ]; then
  cmd+=(--notes-start-tag "$NOTES_START_TAG")
fi

if [ -n "${TITLE:-}" ]; then
  cmd+=(--title "$TITLE")
fi

if [ -n "${DISCUSSION_CATEGORY:-}" ]; then
  cmd+=(--discussion-category "$DISCUSSION_CATEGORY")
fi

if [ ${#assets[@]} -gt 0 ]; then
  cmd+=("${assets[@]}")
fi

echo "tag-to-release: creating release for $TAG in $REPO (prerelease=$is_prerelease, latest=$is_latest)..."
release_url="$("${cmd[@]}")"

# Fetch newly created release id
rel_id=""
rel_json="$(gh release view "$TAG" --repo "$REPO" --json id 2>/dev/null || true)"
if [ -n "$rel_json" ]; then
  rel_id="$(echo "$rel_json" | jq -r '.id // ""')"
fi

set_output "created" "true"
set_output "id" "$rel_id"
set_output "url" "$release_url"
set_output "tag" "$TAG"
set_output "is-prerelease" "$is_prerelease"
set_output "is-latest" "$is_latest"

echo "tag-to-release: release created successfully: $release_url"
