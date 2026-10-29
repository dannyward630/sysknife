#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

python3 - <<'PY'
from pathlib import Path
import sys

try:
    import yaml
except ImportError:
    sys.exit("release main guard: PyYAML is required")

release_path = Path(".github/workflows/release.yml")
ci_path = Path(".github/workflows/ci.yml")
release = yaml.safe_load(release_path.read_text(encoding="utf-8"))
ci = yaml.safe_load(ci_path.read_text(encoding="utf-8"))
preflight = release.get("jobs", {}).get("preflight", {})
steps = preflight.get("steps", [])

if len(steps) < 3 or steps[0].get("name") != "Checkout":
    sys.exit("release main guard: preflight must check out the tagged commit first")
if steps[0].get("with", {}).get("fetch-depth") != 0:
    sys.exit("release main guard: checkout must fetch full history for ancestry checks")

guard = steps[1]
guard_run = guard.get("run", "")
if guard.get("name") != "Require tag commit on main":
    sys.exit("release main guard: ancestry check must be the first step after checkout")
for required in (
    "git fetch origin main:refs/remotes/origin/main",
    'git merge-base --is-ancestor "$GITHUB_SHA" origin/main',
    "::error::",
    "$GITHUB_SHA",
    "exit 1",
):
    if required not in guard_run:
        sys.exit(f"release main guard: ancestry step is missing {required!r}")
if preflight.get("continue-on-error") is True or any(
    step.get("continue-on-error") is True for step in steps
):
    sys.exit("release main guard: preflight must not continue after a failed guard")

ci_guard = next(
    (step for step in steps if step.get("name") == "Require successful CI on tagged commit"),
    None,
)
if ci_guard is None or "bash scripts/check_release_ci.sh" not in ci_guard.get("run", ""):
    sys.exit("release main guard: preflight must require a successful CI run")
if ci_guard.get("continue-on-error") is True:
    sys.exit("release main guard: CI verification must not be allowed to fail")

permissions = preflight.get("permissions", {})
if permissions.get("checks") != "read" or permissions.get("actions") != "read":
    sys.exit("release main guard: preflight needs read-only checks and actions permissions")

ci_runs = [
    step.get("run", "")
    for job in ci.get("jobs", {}).values()
    for step in job.get("steps", [])
]
for test_path in (
    "bash tests/release/release-main-guard.test.sh",
    "bash tests/release/check-release-ci.test.sh",
):
    if test_path not in ci_runs:
        sys.exit(f"release main guard: CI does not invoke {test_path}")

print("release main guard contract passed")
PY
