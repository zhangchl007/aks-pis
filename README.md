# AKS PIS Azure Initialization Review Bundle

This project packages a sanitized set of Azure node-initialization scripts for
review with [AKS Prepared Image Specification (PIS)](https://learn.microsoft.com/azure/aks/prepared-image-specification-overview).

The generated PIS customization installs the review files under
`/opt/azure-init-review` in the prepared image. It validates and copies the
files, but **does not execute any of the bundled initialization scripts**.

The review examples contain redacted host names, addresses, credentials, and
user names; treat them as documentation examples, not deployable configuration.

## What this project contains

| Path | Purpose |
| --- | --- |
| `azure-init-review/` | Sanitized scripts, checksums, and generated PIS JSON |
| `tools/build_azure_init_pis.py` | Verifies the bundle and generates `pis-scripts.json` |
| `azure-init-review/rtx6000-driver-install.sh` | Installs the Microsoft-redistributed Azure GRID vGPU driver for RTX PRO 6000 BSE |
| `tools/build_rtx6000_pis.py` | Validates the RTX installer and generates `pis-scripts-rtx6000.json` |
| `azure-init-review/pis-scripts-rtx6000.json` | PIS customization that installs the Azure GRID driver during image build |
| `azure-init-review/gpu-operator-rtx6000-values.yaml` | Tested GPU Operator values using the PIS driver root and file-based containerd config |
| `azure-init-review/rtx6000-cuda-smoke-job.yaml` | GPU-requesting Job that runs and verifies a real CUDA kernel |
| `docs/pis-scripts-explained.md` | Explains both PIS JSON files, RTX vGPU driver selection, and AKS managed-driver boundaries |
| `docs/azure-init-review-runbook.md` | Safe deployment and verification runbook |
| `docs/manual.md` | General end-to-end AKS PIS Bash example |

## Requirements

To build the JSON locally:

- Python 3.9 or later
- Bash
- `sha256sum`

To create and test a PIS version in Azure, you also need:

- Azure CLI 2.85.0 or later
- `aks-preview` extension 21.0.0b5 or later
- An Azure subscription with the
  `AKSPreparedImageSpecificationPreview` feature registered
- An existing AKS cluster for isolated testing

See the [review runbook](docs/azure-init-review-runbook.md) for the complete
Azure prerequisites and least-privilege RBAC steps.

## Quick start

Run these commands from the project root.

### 1. Verify the review bundle

```bash
cd azure-init-review
sha256sum --check SHA256SUMS

while IFS= read -r script; do
  bash -n "${script}" || exit 1
done < <(find . -type f -name '*.sh' -print)

cd ..
```

Expected result:

- Every checksum reports `OK`.
- `bash -n` exits successfully without output.
- No bundled script is executed.

### 2. Generate the PIS customization JSON

```bash
python3 tools/build_azure_init_pis.py
```

Example output:

```text
Wrote .../azure-init-review/pis-scripts.json
Bundle ID: <sha256>
Bundled files: 8 (scripts are copied, never executed)
```

The generator:

1. Verifies that `SHA256SUMS` covers the expected bundle files.
2. Checks every file digest.
3. Runs `bash -n` against each shell script.
4. Builds one `NodeImageBuildTime` customization entry.
5. Writes `azure-init-review/pis-scripts.json` atomically.

To write the result to another location:

```bash
python3 tools/build_azure_init_pis.py --output /tmp/pis-scripts.json
```

To generate the RTX custom-driver PIS JSON:

```bash
python3 tools/build_rtx6000_pis.py
```

The RTX installer uses the Microsoft-redistributed Azure GRID vGPU runfile
recommended for the NCv6 RTX PRO 6000 BSE series. Generic NVIDIA runfiles and
Ubuntu driver packages are not substitutes for this vGPU-specific artifact.
The tested setup uses PIS version
`custom-azure-grid-595.91.07-v5-postready-restore` to package the custom
driver, a pool-scoped DaemonSet to restore modules after node readiness,
and GPU Operator v26.7.2 / Toolkit v1.20.1 for GPU container support.
Operator driver installation is disabled; `RUNTIME_CONFIG_SOURCE=file`
keeps its containerd configuration compatible with AKS.

The RTX Spot node is Ready with one allocatable GPU. Both the Operator
CUDA validator and the independent CUDA kernel Job passed. Performance
comparisons and long-term stability have not been measured. See
[the PIS runbook](docs/azure-init-review-runbook.md) and
[the customization explanation](docs/pis-scripts-explained.md).

### 3. Inspect the generated JSON

```bash
python3 -m json.tool azure-init-review/pis-scripts.json >/dev/null
python3 -m json.tool azure-init-review/pis-scripts-rtx6000.json >/dev/null
```

The JSON contains one Bash customization named
`azure-init-review-bundle`. During image preparation it:

- requires root access;
- decodes the review files into a temporary directory;
- verifies all checksums;
- installs the files as non-executable files under
  `/opt/azure-init-review`;
- refuses to overwrite different content already at that destination.

## Optional Azure example

Only use this example in an approved test environment. Replace all placeholder
values before running it.

```bash
export RESOURCE_GROUP="<resource-group>"
export LOCATION="<azure-region>"
export PIS_NAME="azure-init-review"
export PIS_VERSION="v1"

az aks prepared-image-specification create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PIS_NAME}" \
  --version "${PIS_VERSION}" \
  --location "${LOCATION}" \
  --customization-scripts @azure-init-review/pis-scripts.json
```

Creating a PIS version does not execute the reviewed initialization scripts. It
only installs them as static review files in the prepared image.

Follow the [review runbook](docs/azure-init-review-runbook.md) to:

- grant the AKS identity read access to the PIS resource;
- create an isolated, tainted test node pool;
- inspect `/opt/azure-init-review` from a node debug container;
- validate checksums and file permissions;
- clean up or roll back the test.

## Updating the bundle

When an approved source file changes:

1. Review and sanitize the change.
2. Update `azure-init-review/SHA256SUMS`.
3. Run the verification commands from the quick start.
4. Regenerate `azure-init-review/pis-scripts.json`.
5. Review the generated JSON before creating a new PIS version.

PIS versions should be treated as immutable. Create a new version rather than
overwriting a version already used by a node pool.

## Important limitations

- The package uses `.example.invalid`, `192.0.2.x`, and
  `REDACTED_AUTHORIZATION` placeholders.
- Static syntax and checksum validation do not prove runtime compatibility.
- The original scripts can modify disks, DNS, users, sudo access, NTP,
  firewalls, SELinux, monitoring, cron jobs, and log retention.
- The bundle must not be converted into an executable PIS build-time script
  without a separate security and lifecycle redesign.
- PIS can add significant time to initial node-pool creation. Testing in this
  project found that ordinary node-pool creation was more suitable for a
  workflow that recreates pools every day.

## Documentation

- [Review bundle notes](azure-init-review/README.md)
- [PIS review deployment runbook](docs/azure-init-review-runbook.md)
- [General AKS PIS Bash walkthrough](docs/manual.md)
- [Microsoft Learn: AKS Prepared Image Specification](https://learn.microsoft.com/azure/aks/prepared-image-specification-overview)
