#!/usr/bin/env python3
"""Build a PIS customization JSON that copies the reviewed bundle without running it."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import NoReturn


PROJECT_ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ROOT = PROJECT_ROOT / "azure-init-review"
FILES = (
    "README.md",
    "SHA256SUMS",
    "k8s_init.azure.redacted.sh",
    "initialization/scripts/dns_update_workspace.sh",
    "initialization/scripts/init_user.sh",
    "initialization/scripts/ntpdate_eu_set.sh",
    "initialization/scripts/ntpdate_set.sh",
    "scripts/del_log.sh",
)
SCRIPT_FILES = tuple(path for path in FILES if path.endswith(".sh"))
PIS_SCRIPT_NAME = "azure-init-review-bundle"
DESTINATION = "/opt/azure-init-review"


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_and_verify_bundle() -> tuple[dict[str, bytes], str]:
    checksums_path = BUNDLE_ROOT / "SHA256SUMS"
    if not checksums_path.is_file() or checksums_path.is_symlink():
        fail(f"missing regular checksum file: {checksums_path}")

    checksums: dict[str, str] = {}
    for line_number, line in enumerate(
        checksums_path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        match = re.fullmatch(r"([0-9a-fA-F]{64})  (.+)", line)
        if not match:
            fail(f"invalid SHA256SUMS entry on line {line_number}")
        digest, relative_name = match.groups()
        relative_path = PurePosixPath(relative_name)
        if relative_path.is_absolute() or ".." in relative_path.parts:
            fail(f"unsafe path in SHA256SUMS: {relative_name}")
        if relative_name in checksums:
            fail(f"duplicate SHA256SUMS entry: {relative_name}")
        checksums[relative_name] = digest.lower()

    expected_names = set(FILES) - {"SHA256SUMS"}
    if set(checksums) != expected_names:
        missing = sorted(expected_names - set(checksums))
        extra = sorted(set(checksums) - expected_names)
        fail(f"SHA256SUMS must cover exactly the bundle files; missing={missing}, extra={extra}")

    contents: dict[str, bytes] = {}
    for relative_name in FILES:
        source_path = BUNDLE_ROOT / relative_name
        if source_path.is_symlink() or not source_path.is_file():
            fail(f"bundle input must be a regular file: {relative_name}")
        content = source_path.read_bytes()
        digest = hashlib.sha256(content).hexdigest()
        if relative_name in checksums and digest != checksums[relative_name]:
            fail(f"SHA-256 mismatch for {relative_name}")
        contents[relative_name] = content

    for relative_name in SCRIPT_FILES:
        result = subprocess.run(
            ["bash", "-n", str(BUNDLE_ROOT / relative_name)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode:
            fail(f"bash -n failed for {relative_name}:\n{result.stderr}")

    bundle_id = hashlib.sha256(contents["SHA256SUMS"]).hexdigest()
    return contents, bundle_id


def make_customization_script(contents: dict[str, bytes], bundle_id: str) -> str:
    parts = [
        "#!/usr/bin/env bash",
        "set -Eeuo pipefail",
        "",
        'if [[ "$(id -u)" -ne 0 ]]; then',
        '  echo "[ERROR] PIS bundle installation requires root." >&2',
        "  exit 1",
        "fi",
        "",
        'for cmd in base64 diff mkdir mktemp mv rm sha256sum; do',
        '  command -v "$cmd" >/dev/null 2>&1 || {',
        '    echo "[ERROR] Required command is missing: $cmd" >&2',
        "    exit 1",
        "  }",
        "done",
        "",
        f'destination="{DESTINATION}"',
        'stage="$(mktemp -d /opt/.azure-init-review.XXXXXX)"',
        'cleanup() {',
        '  if [[ -n "${stage:-}" && -d "$stage" ]]; then',
        '    rm -rf -- "$stage"',
        "  fi",
        "}",
        "trap cleanup EXIT",
        "",
        'chmod 0755 "$stage"',
    ]

    for index, (relative_name, content) in enumerate(contents.items(), start=1):
        relative_path = PurePosixPath(relative_name)
        parent = relative_path.parent
        if str(parent) != ".":
            parts.append(f'mkdir -p -- "$stage/{parent.as_posix()}"')
            parts.append(f'chmod 0755 "$stage/{parent.as_posix()}"')
        marker = f"AZURE_INIT_PAYLOAD_{index}"
        encoded = base64.b64encode(content).decode("ascii")
        wrapped = "\n".join(
            encoded[offset : offset + 76] for offset in range(0, len(encoded), 76)
        )
        parts.extend(
            [
                f"base64 --decode > \"$stage/{relative_name}\" <<'{marker}'",
                wrapped,
                marker,
            ]
        )

    parts.extend(
        [
            'chmod 0644 "$stage/README.md" "$stage/SHA256SUMS"',
            'chmod 0644 "$stage/k8s_init.azure.redacted.sh"',
            'chmod 0644 "$stage/initialization/scripts/"*.sh',
            'chmod 0644 "$stage/scripts/"*.sh',
            "(",
            '  cd "$stage"',
            "  sha256sum --check SHA256SUMS",
            ")",
            "cat > \"$stage/BUNDLE-MANIFEST.txt\" <<'BUNDLE_MANIFEST'",
            "bundle_id=" + bundle_id,
            "destination=" + DESTINATION,
            "content=review-only scripts; not executed during PIS image build",
            "source_checksums=SHA256SUMS",
            "BUNDLE_MANIFEST",
            "",
            'if [[ -e "$destination" || -L "$destination" ]]; then',
            '  if [[ -d "$destination" ]] && diff -qr -- "$stage" "$destination" >/dev/null; then',
            '    echo "[INFO] Identical azure-init-review bundle already installed; no changes made."',
            "    exit 0",
            "  fi",
            '  echo "[ERROR] Destination already exists with different contents: $destination" >&2',
            "  exit 1",
            "fi",
            'mv -T -- "$stage" "$destination"',
            'stage=""',
            'echo "[INFO] Installed review-only scripts at $destination (bundle_id='
            + bundle_id
            + ')."',
            'echo "[INFO] No bundled initialization script was executed."',
            "",
        ]
    )
    return "\n".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Generate PIS JSON that validates and copies azure-init-review into "
            "/opt/azure-init-review without executing the bundled scripts."
        )
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=PROJECT_ROOT / "azure-init-review" / "pis-scripts.json",
        help="output JSON path (default: azure-init-review/pis-scripts.json)",
    )
    args = parser.parse_args()

    output_path = args.output.resolve()
    protected_paths = {BUNDLE_ROOT / name for name in FILES}
    protected_paths.add(Path(__file__).resolve())
    if output_path in protected_paths:
        fail(f"refusing to overwrite an input file: {output_path}")

    contents, bundle_id = load_and_verify_bundle()
    script = make_customization_script(contents, bundle_id)
    syntax_check = subprocess.run(
        ["bash", "-n"],
        input=script,
        check=False,
        capture_output=True,
        text=True,
    )
    if syntax_check.returncode:
        fail(f"generated customization script failed bash -n:\n{syntax_check.stderr}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=output_path.parent,
        prefix=f".{output_path.name}.",
        suffix=".tmp",
        delete=False,
    ) as temp_file:
        temp_path = Path(temp_file.name)
        json.dump(
            [
                {
                    "name": PIS_SCRIPT_NAME,
                    "scriptType": "Bash",
                    "executionPoint": "NodeImageBuildTime",
                    "postScriptAction": "None",
                    "script": script,
                }
            ],
            temp_file,
            ensure_ascii=False,
            indent=2,
        )
        temp_file.write("\n")

    temp_path.replace(output_path)
    print(f"Wrote {output_path}")
    print(f"Bundle ID: {bundle_id}")
    print(f"Bundled files: {len(contents)} (scripts are copied, never executed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
