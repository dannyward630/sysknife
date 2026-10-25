#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PYTHON'
from pathlib import Path
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.exit("workflow-timeouts: PyYAML is required")


def missing_timeouts(paths):
    missing = []
    for path in paths:
        try:
            workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError) as error:
            raise RuntimeError(f"cannot read {path}: {error}") from error
        if not isinstance(workflow, dict) or not isinstance(workflow.get("jobs"), dict):
            raise RuntimeError(f"{path} has no jobs mapping")
        for name, job in workflow["jobs"].items():
            if not isinstance(job, dict):
                raise RuntimeError(f"{path} job {name} is not a mapping")
            if "uses" not in job and "timeout-minutes" not in job:
                missing.append(f"{path.name}/{name}")
    return missing


with tempfile.TemporaryDirectory(prefix="workflow-timeouts-") as directory:
    fixture = Path(directory) / "fixture.yml"
    fixture.write_text(
        "jobs:\n"
        "  fast:\n"
        "    runs-on: ubuntu-latest\n"
        "    steps: []\n"
        "  bounded:\n"
        "    runs-on: ubuntu-latest\n"
        "    timeout-minutes: 5\n"
        "    steps: []\n"
        "  reusable:\n"
        "    uses: ./.github/workflows/publish-mcp.yml\n",
        encoding="utf-8",
    )
    expected = ["fixture.yml/fast"]
    actual = missing_timeouts([fixture])
    if actual != expected:
        raise RuntimeError(f"fixture expected {expected}, got {actual}")

workflows = Path(sys.argv[1]) / ".github" / "workflows"
paths = sorted([*workflows.glob("*.yml"), *workflows.glob("*.yaml")])
if not paths:
    raise RuntimeError(f"no workflow files found under {workflows}")

missing = missing_timeouts(paths)
if missing:
    print("FAIL: workflow jobs missing timeout-minutes:", file=sys.stderr)
    for job in missing:
        print(f"  {job}", file=sys.stderr)
    sys.exit(1)

print(f"workflow-timeouts: checked all jobs in {len(paths)} workflow files")
PYTHON
