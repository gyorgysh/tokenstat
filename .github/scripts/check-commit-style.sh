#!/usr/bin/env bash
#
# Validate that every commit in a pull request, and the pull request title
# itself, follow the Conventional Commits format documented in CONTRIBUTING.md.
#
# Inputs are read from the environment rather than interpolated into the script,
# so a crafted branch name or title cannot inject shell commands.
#
# On a push, the range is what the push is adding. An unreachable or absent
# base (a first push, or a force push) leaves nothing to compare against, and
# the commits are skipped rather than the job failing on history it cannot see.
#
#   BASE_SHA   merge base of the pull request, or the commit before the push
#   HEAD_SHA   head commit of the pull request, or of the push
#   PR_TITLE   pull request title, which becomes the squashed commit subject

set -euo pipefail

TYPES='feat|fix|perf|refactor|docs|test|build|ci|chore|revert'
SUBJECT_PATTERN="^(${TYPES})(\([a-z0-9._-]+\))?!?: [a-z0-9].*"
MAX_SUBJECT=72

failed=0

check_subject() {
  local label="$1"
  local subject="$2"

  if [[ "$subject" =~ ^(Merge|Revert)\  ]]; then
    return 0
  fi

  if ! [[ "$subject" =~ $SUBJECT_PATTERN ]]; then
    printf '%s does not match the required format:\n  %s\n' "$label" "$subject"
    failed=1
    return 0
  fi

  if [ "${#subject}" -gt "$MAX_SUBJECT" ]; then
    printf '%s subject is %s characters, limit is %s:\n  %s\n' \
      "$label" "${#subject}" "$MAX_SUBJECT" "$subject"
    failed=1
  fi

  if [[ "$subject" == *. ]]; then
    printf '%s subject ends with a period:\n  %s\n' "$label" "$subject"
    failed=1
  fi
}

check_body() {
  local label="$1"
  local body="$2"

  # Metadata that must never reach a published artifact.
  if printf '%s' "$body" | grep -qiE '(co-authored-by|generated with|claude-session|session-id)'; then
    printf '%s body contains tooling attribution or a session identifier\n' "$label"
    failed=1
  fi

  if printf '%s' "$body" | grep -qE '(/Users/|/home/[a-z]|C:\\Users\\)'; then
    printf '%s body contains an absolute local path\n' "$label"
    failed=1
  fi
}

if [ -n "${PR_TITLE:-}" ]; then
  check_subject "pull request title" "$PR_TITLE"
fi

if [ -n "${BASE_SHA:-}" ] && [ -n "${HEAD_SHA:-}" ] \
  && [ "$BASE_SHA" != "0000000000000000000000000000000000000000" ] \
  && git cat-file -e "${BASE_SHA}^{commit}" 2> /dev/null; then
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    subject=$(git log -1 --format=%s "$sha")
    body=$(git log -1 --format=%B "$sha")
    check_subject "commit ${sha:0:8}" "$subject"
    check_body "commit ${sha:0:8}" "$body"
  done < <(git rev-list "${BASE_SHA}..${HEAD_SHA}")
fi

if [ "$failed" -ne 0 ]; then
  printf '\nSee CONTRIBUTING.md for the commit message format.\n'
  exit 1
fi

printf 'Commit style check passed.\n'
