#!/usr/bin/env python3
"""Build the PIS customization JSON for the Azure RTX vGPU GRID driver."""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = PROJECT_ROOT / "azure-init-review" / "rtx6000-driver-install.sh"
OUTPUT_PATH = PROJECT_ROOT / "azure-init-review" / "pis-scripts-rtx6000.json"


def main() -> int:
    script = SCRIPT_PATH.read_text(encoding="utf-8")
    result = subprocess.run(
        ["bash", "-n"],
        input=script,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise SystemExit(f"RTX driver customization failed bash -n:\n{result.stderr}")

    restore_script_match = re.search(
        r"""cat > "\$\{RESTORE_SCRIPT\}" <<'EOF'\n(.*?)\nEOF""",
        script,
        re.DOTALL,
    )
    if restore_script_match is None:
        raise SystemExit("RTX driver customization is missing its module-restore script.")

    restore_result = subprocess.run(
        ["bash", "-n"],
        input=restore_script_match.group(1),
        check=False,
        capture_output=True,
        text=True,
    )
    if restore_result.returncode:
        raise SystemExit(
            f"NVIDIA module-restore script failed bash -n:\n{restore_result.stderr}"
        )

    forbidden_kubelet_changes = (
        "kubelet.service",
        "/etc/systemd/system/kubelet.service.d",
        "ExecStartPre=",
        "ExecStartPost=",
    )
    if any(marker in script for marker in forbidden_kubelet_changes):
        raise SystemExit(
            "RTX driver customization must not modify or hook the AKS-managed kubelet service."
        )

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=OUTPUT_PATH.parent,
        prefix=f".{OUTPUT_PATH.name}.",
        suffix=".tmp",
        delete=False,
    ) as temporary:
        temporary_path = Path(temporary.name)
        json.dump(
            [
                {
                    "name": "rtx6000-azure-grid-vgpu-595-91-07",
                    "scriptType": "Bash",
                    "executionPoint": "NodeImageBuildTime",
                    "postScriptAction": "None",
                    "script": script,
                }
            ],
            temporary,
            ensure_ascii=False,
            indent=2,
        )
        temporary.write("\n")

    temporary_path.replace(OUTPUT_PATH)
    print(f"Wrote {OUTPUT_PATH}")
    print("Driver: Microsoft-redistributed Azure GRID vGPU 595.91.07 (open kernel module, DKMS)")
    print("Kernel modules and a restore helper are staged under /opt and /usr/local/sbin.")
    print("After a node is Ready, use rtx6000-module-restore-daemonset.yaml to restore modules without modifying kubelet.")
    print("This is the NCv6 RTX PRO 6000 BSE vGPU package documented by Microsoft Learn.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
