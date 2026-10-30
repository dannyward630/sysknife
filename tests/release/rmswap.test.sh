#!/usr/bin/env bash
# Guards sysknife-mount-edit's rmswap against the arbitrary-root-unlink class.
#
# op_rmswap charset-validated its --file and then os.unlink()d it as root. Every
# step before the unlink tolerates a non-swap path: swapoff runs with check=False
# so it fails silently, and the fstab rewrite is a no-op when no entry matches.
# `--file /etc/shadow` therefore reached the unlink and deleted the shadow file.
# The helper must only remove a path the host actually knows as a swap file.
# Pure-function test: no root, no real swapoff, no writes outside a tempdir.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/packaging/sysknife-mount-edit"

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

python3 - "$SCRIPT" <<'PY'
import contextlib
import importlib.util
import io
import os
import sys
import tempfile
from importlib.machinery import SourceFileLoader

script_path = sys.argv[1]
loader = SourceFileLoader("mount_edit", script_path)
spec = importlib.util.spec_from_loader("mount_edit", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

failures = []

if getattr(mod, "known_swap_files", None) is None:
    print("FAIL: known_swap_files() missing from sysknife-mount-edit")
    sys.exit(1)
if getattr(mod, "PROC_SWAPS", None) is None:
    print("FAIL: PROC_SWAPS missing from sysknife-mount-edit")
    sys.exit(1)


class Args:
    def __init__(self, file):
        self.file = file


class FakeCompleted:
    def __init__(self, returncode=0, stderr=b""):
        self.returncode = returncode
        self.stderr = stderr


def run_rmswap(path, swapoff_returncode=0, swapoff_stderr=b""):
    """Run op_rmswap with swapoff stubbed out; return its exit code and stderr."""
    real_run = mod.subprocess.run
    result = FakeCompleted(swapoff_returncode, swapoff_stderr)

    def fake_run(*args, **kwargs):
        if kwargs.get("stderr") == mod.subprocess.PIPE:
            return result
        return FakeCompleted(swapoff_returncode, None)

    mod.subprocess.run = fake_run
    captured_stderr = io.StringIO()
    try:
        with contextlib.redirect_stderr(captured_stderr):
            try:
                mod.op_rmswap(Args(path))
                code = None
            except SystemExit as exc:
                code = exc.code
        return code, captured_stderr.getvalue()
    finally:
        mod.subprocess.run = real_run


with tempfile.TemporaryDirectory() as d:
    fstab = os.path.join(d, "fstab")
    swaps = os.path.join(d, "swaps")
    victim = os.path.join(d, "shadow")
    declared = os.path.join(d, "declared-swap")
    active = os.path.join(d, "active-swap")
    active_only = os.path.join(d, "active-only-swap")

    with open(victim, "w") as fh:
        fh.write("root:!:19000:0:99999:7:::\n")
    for p in (declared, active, active_only):
        with open(p, "w") as fh:
            fh.write("swapdata")

    with open(fstab, "w") as fh:
        fh.write("UUID=1234\t/\text4\tdefaults\t0\t1\n")
        fh.write(f"{declared}\tnone\tswap\tsw,nofail\t0\t0\n")
        fh.write(f"{active}\tnone\tswap\tsw,nofail\t0\t0\n")
        # A commented-out entry must not make a path "known".
        fh.write(f"#{victim}\tnone\tswap\tsw,nofail\t0\t0\n")
    with open(swaps, "w") as fh:
        fh.write("Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n")
        fh.write(f"{active}\t\t\t\tfile\t\t2097148\t\t0\t\t-2\n")
        fh.write(f"{active_only}\t\t\t\tfile\t\t2097148\t\t0\t\t-1\n")
        fh.write("/dev/sda2\t\t\t\tpartition\t2097148\t\t0\t\t-3\n")

    mod.FSTAB = fstab
    mod.PROC_SWAPS = swaps

    # 1. known_swap_files sees the fstab declaration and the active file, and
    #    neither the commented-out line nor the swap *partition*.
    known = mod.known_swap_files()
    if declared not in known:
        failures.append("known_swap_files missed the fstab-declared swap file")
    if active not in known:
        failures.append("known_swap_files missed the active /proc/swaps file")
    if active_only not in known:
        failures.append("known_swap_files missed the /proc/swaps-only file")
    if any(mod.fstab_field1(line) == active_only for line in mod.read_fstab()):
        failures.append("/proc/swaps-only test file unexpectedly appeared in fstab")
    if victim in known:
        failures.append("known_swap_files treated a commented-out fstab line as a swap file")
    if "/dev/sda2" in known:
        failures.append("known_swap_files treated a swap partition as a removable swap file")

    # 2. THE BUG: an unrelated root-owned file must not be deleted.
    code, _ = run_rmswap(victim)
    if code in (None, 0):
        failures.append(f"op_rmswap did NOT refuse an unknown path (exit {code!r})")
    if not os.path.exists(victim):
        failures.append("op_rmswap DELETED a file that is not a swap file")

    # 3. A symlink that happens to be declared as swap is still not ours to
    #    follow — unlink removes the link, but accepting it means fstab content
    #    decides what root deletes.
    link = os.path.join(d, "link-swap")
    os.symlink(victim, link)
    with open(fstab, "a") as fh:
        fh.write(f"{link}\tnone\tswap\tsw,nofail\t0\t0\n")
    code, _ = run_rmswap(link)
    if code in (None, 0):
        failures.append(f"op_rmswap did NOT refuse a symlinked swap path (exit {code!r})")

    # 4. A stale fstab entry is not active swap. A failed swapoff is expected
    #    here, so the file and its declaration can still be removed.
    code, _ = run_rmswap(
        declared,
        swapoff_returncode=1,
        swapoff_stderr=b"not an active swap area",
    )
    if code not in (None, 0):
        failures.append(f"op_rmswap refused a legitimate declared swap file (exit {code!r})")
    if os.path.exists(declared):
        failures.append("op_rmswap did not remove a legitimate declared swap file")
    if any(mod.fstab_field1(line) == declared for line in mod.read_fstab()):
        failures.append("op_rmswap kept the fstab entry for an inactive swap file")

    # 5. A failed swapoff for an active file must preserve both the file and its
    #    fstab entry and surface the utility's stderr.
    code, message = run_rmswap(
        active,
        swapoff_returncode=1,
        swapoff_stderr=b"device is busy",
    )
    if code in (None, 0):
        failures.append(f"op_rmswap did NOT refuse a failed swapoff for an active file (exit {code!r})")
    if not os.path.exists(active):
        failures.append("op_rmswap DELETED an active swap file after swapoff failed")
    if not any(mod.fstab_field1(line) == active for line in mod.read_fstab()):
        failures.append("op_rmswap removed the fstab entry after swapoff failed")
    if "device is busy" not in message:
        failures.append("op_rmswap did not include swapoff stderr in its refusal")

    # 6. If /proc/swaps cannot be read, a failed swapoff is not evidence that
    #    the active path is safe to remove. Preserve the file and fstab entry.
    mod.PROC_SWAPS = os.path.join(d, "missing-swaps")
    code, message = run_rmswap(
        active,
        swapoff_returncode=1,
        swapoff_stderr=b"cannot inspect active swaps",
    )
    if code in (None, 0):
        failures.append(f"op_rmswap treated unreadable /proc/swaps as inactive (exit {code!r})")
    if not os.path.exists(active):
        failures.append("op_rmswap deleted a swap file when it could not inspect /proc/swaps")
    if not any(mod.fstab_field1(line) == active for line in mod.read_fstab()):
        failures.append("op_rmswap removed the fstab entry when /proc/swaps was unreadable")
    if "cannot inspect active swaps" not in message:
        failures.append("op_rmswap did not include swapoff stderr when /proc/swaps was unreadable")

    mod.PROC_SWAPS = swaps

    # 7. A successful swapoff still removes a genuinely active file.
    code, _ = run_rmswap(active)
    if code not in (None, 0):
        failures.append(f"op_rmswap refused a legitimate active swap file (exit {code!r})")
    if os.path.exists(active):
        failures.append("op_rmswap did not remove a legitimate active swap file")

    # 8. A file known only from /proc/swaps (no fstab line) is still removable.
    code, _ = run_rmswap(active_only)
    if code not in (None, 0):
        failures.append(f"op_rmswap refused a swap file known only from /proc/swaps (exit {code!r})")
    if os.path.exists(active_only):
        failures.append("op_rmswap did not remove a swap file known only from /proc/swaps")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("ok: sysknife-mount-edit only removes paths the host knows as swap files")
print("ok: rmswap still removes genuine declared and active swap files")
PY
