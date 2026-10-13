import contextlib
import io
import json
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools import build_rtx6000_pis as builder


class RTX6000PISTests(unittest.TestCase):
    def setUp(self):
        self.script = builder.SCRIPT_PATH.read_text(encoding="utf-8")

    def marker_cleanup(self, marker, prefix=""):
        match = re.search(
            r'if \[\[ -f "\$\{AKS_GPU_PREBAKE_MARKER\}" \]\]; then\n.*?\nfi',
            self.script,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        return subprocess.run(
            ["bash", "-e", "-s"],
            input=(
                f"readonly AKS_GPU_PREBAKE_MARKER={shlex.quote(str(marker))}\n"
                + prefix
                + match.group(0)
                + "\n"
            ),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_stale_marker_is_removed_without_touching_other_files(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "dkms-marker"
            unrelated = Path(directory) / "unrelated"
            marker.write_text("driver_version=580.159.04\ndriver_kind=cuda\n")
            unrelated.write_text("keep")
            result = self.marker_cleanup(marker)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())
            self.assertEqual(unrelated.read_text(), "keep")
            self.assertIn("Removed stale AKS managed-driver prebake marker", result.stdout)

    def test_absent_marker_is_supported(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.marker_cleanup(Path(directory) / "dkms-marker")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("Removed stale", result.stdout)

    def test_marker_removal_failure_does_not_report_success(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "dkms-marker"
            marker.write_text("driver_kind=cuda\n")
            result = self.marker_cleanup(
                marker, 'rm() { echo "forced removal failure" >&2; return 1; }\n'
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(marker.exists())
            self.assertIn("forced removal failure", result.stderr)
            self.assertNotIn("Removed stale", result.stdout)

    def test_marker_is_retired_after_driver_validation(self):
        self.assertGreater(
            self.script.index('rm -- "${AKS_GPU_PREBAKE_MARKER}"'),
            self.script.index('update-initramfs -u -k "${kernel_version}"'),
        )
        self.assertGreater(
            self.script.index('update-initramfs -u -k "${kernel_version}"'),
            self.script.index('module_vermagic="$(modinfo'),
        )

    def test_standard_boot_configuration_loads_all_four_modules(self):
        match = re.search(
            r'cat > "\$\{MODULES_LOAD_CONFIG\}" <<\'EOF\'\n(.*?)\nEOF',
            self.script,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        self.assertEqual(
            match.group(1).splitlines(),
            ["nvidia", "nvidia_modeset", "nvidia_uvm", "nvidia_drm"],
        )
        self.assertIn("/etc/modules-load.d/aks-custom-nvidia.conf", self.script)
        self.assertNotIn("RESTORE_SCRIPT", self.script)
        self.assertNotIn("MODULE_ARCHIVE_ROOT", self.script)
        self.assertNotIn("mknod ", self.script)

    def test_generator_embeds_exact_native_installer(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "pis.json"
            with patch.object(builder, "OUTPUT_PATH", output), contextlib.redirect_stdout(
                io.StringIO()
            ):
                self.assertEqual(builder.main(), 0)
            data = json.loads(output.read_text())
            self.assertEqual(len(data), 1)
            self.assertEqual(data[0]["executionPoint"], "NodeImageBuildTime")
            self.assertEqual(data[0]["script"], self.script)

    def test_operator_uses_default_host_driver_detection(self):
        values = (
            builder.PROJECT_ROOT
            / "azure-init-review"
            / "gpu-operator-rtx6000-values.yaml"
        ).read_text()
        self.assertNotIn("hostPaths:", values)
        self.assertNotIn("driverInstallDir:", values)

    def test_generator_rejects_invalid_bash_and_kubelet_hooks(self):
        for script, message in (
            ("if then\n", "failed bash -n"),
            ("echo kubelet.service\n", "must not modify or hook"),
        ):
            with self.subTest(script=script), tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "install.sh"
                output = Path(directory) / "pis.json"
                source.write_text(script)
                output.write_text("unchanged")
                with patch.object(builder, "SCRIPT_PATH", source), patch.object(
                    builder, "OUTPUT_PATH", output
                ):
                    with self.assertRaisesRegex(SystemExit, message):
                        builder.main()
                self.assertEqual(output.read_text(), "unchanged")


if __name__ == "__main__":
    unittest.main()
