#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

helper="scripts/check_release_ci.sh"
[[ -f "$helper" ]] || {
    printf 'FAIL: missing %s\n' "$helper" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    *"/check-runs?per_page=100"*)
        [[ "${RELEASE_CI_TEST_MODE:-success}" == "no-check-runs" ]] || printf '101\n'
        ;;
    *"/actions/runs/101"*)
        sha="${GITHUB_SHA:?}"
        case "${RELEASE_CI_TEST_MODE:-success}" in
            success) printf 'ci\t%s\tcompleted\tsuccess\n' "$sha" ;;
            wrong-workflow) printf 'not-ci\t%s\tcompleted\tsuccess\n' "$sha" ;;
            wrong-sha) printf 'ci\t%s\tcompleted\tsuccess\n' "$(printf '0%.0s' {1..40})" ;;
            failure) printf 'ci\t%s\tcompleted\tfailure\n' "$sha" ;;
            incomplete) printf 'ci\t%s\tin_progress\t\n' "$sha" ;;
        esac
        ;;
    *)
        printf 'unexpected gh invocation: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$tmp/bin/gh"

sha="0123456789abcdef0123456789abcdef01234567"
run_helper() {
    local mode="$1"
    PATH="$tmp/bin:$PATH" \
        RELEASE_CI_TEST_MODE="$mode" \
        REPO="lacs-project/sysknife" \
        GH_TOKEN="test-token" \
        GITHUB_SHA="$sha" \
        bash "$helper"
}

run_helper success

for mode in no-check-runs wrong-workflow wrong-sha failure incomplete; do
    if output="$(run_helper "$mode" 2>&1)"; then
        printf 'FAIL: %s unexpectedly passed\n' "$mode" >&2
        exit 1
    fi
    grep -Fq "$sha" <<<"$output" || {
        printf 'FAIL: %s refusal did not name the release SHA\n' "$mode" >&2
        exit 1
    }
done

printf 'release CI check contract passed\n'
