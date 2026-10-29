#!/usr/bin/env bash
set -euo pipefail

repo="${REPO:-}"
release_sha="${GITHUB_SHA:-}"

if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    printf '::error::REPO must be owner/name; received %q\n' "$repo" >&2
    exit 1
fi
if [[ ! "$release_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    printf '::error::GITHUB_SHA must be a 40-character commit SHA; received %q\n' "$release_sha" >&2
    exit 1
fi
if [[ -z "${GH_TOKEN:-}" ]]; then
    printf '::error::GH_TOKEN is required to verify CI for release commit %s\n' "$release_sha" >&2
    exit 1
fi

release_sha_lower="$(printf '%s' "$release_sha" | tr '[:upper:]' '[:lower:]')"
run_ids_output="$(gh api --paginate \
    --jq '.check_runs[]? | (.details_url // "") | try capture("/actions/runs/(?<run_id>[0-9]+)/job/").run_id catch empty' \
    "repos/${repo}/commits/${release_sha}/check-runs?per_page=100")" || {
    printf '::error::Could not read check runs for release commit %s\n' "$release_sha" >&2
    exit 1
}

if [[ -z "$run_ids_output" ]]; then
    printf '::error::No GitHub Actions check runs were found for release commit %s\n' "$release_sha" >&2
    exit 1
fi

run_ids_output="$(sort -u <<< "$run_ids_output")"
while IFS= read -r run_id; do
    if [[ ! "$run_id" =~ ^[0-9]+$ ]]; then
        printf '::error::GitHub returned an invalid Actions run ID for release commit %s\n' "$release_sha" >&2
        exit 1
    fi

    run_data="$(gh api "repos/${repo}/actions/runs/${run_id}" \
        --jq '[.name, .head_sha, .event, .status, .conclusion] | @tsv')" || {
        printf '::error::Could not read Actions run %s for release commit %s\n' "$run_id" "$release_sha" >&2
        exit 1
    }
    IFS=$'\t' read -r workflow_name run_sha event status conclusion <<< "$run_data"
    run_sha_lower="$(printf '%s' "$run_sha" | tr '[:upper:]' '[:lower:]')"

    if [[ "$workflow_name" == ci && "$event" == push && "$run_sha_lower" == "$release_sha_lower" && \
        "$status" == completed && "$conclusion" == success ]]; then
        printf 'Found successful ci workflow run %s for release commit %s\n' "$run_id" "$release_sha"
        exit 0
    fi
done <<< "$run_ids_output"

printf '::error::No completed successful ci workflow run was found for release commit %s\n' "$release_sha" >&2
exit 1
