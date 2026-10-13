#!/usr/bin/env bash
set -Eeuo pipefail

readonly DRIVER_VERSION="595.91.07"
readonly DRIVER_URL="https://download.microsoft.com/download/a7cb6d36-3bbc-43d6-9e88-e0842e6f9ab9/NVIDIA-Linux-x86_64-${DRIVER_VERSION}-grid-azure.run"
readonly DRIVER_ETAG='"0x5CC7884478050ADF7A438E998A6E37D3AD7EDB092C8835A0F88F79D61F790107"'
readonly DRIVER_SIZE_BYTES="429294357"
readonly NVIDIA_SMI_PACKAGE="nvidia-utils-595-server=595.91.07-0ubuntu0.24.04.1"
readonly AKS_GPU_PREBAKE_MARKER="/opt/azure/aks-gpu/dkms-marker"
readonly MODULES_LOAD_CONFIG="/etc/modules-load.d/aks-custom-nvidia.conf"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] Azure GRID vGPU driver installation requires root." >&2
  exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "[ERROR] Unsupported architecture: $(uname -m)" >&2
  exit 1
fi

if ! grep -q '^ID=ubuntu$' /etc/os-release; then
  echo "[ERROR] This installer is validated only for Ubuntu AKS node images." >&2
  exit 1
fi

for command_name in apt-get curl depmod dpkg dpkg-deb dpkg-query dkms install modinfo modprobe update-initramfs; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "[ERROR] Required command is missing: ${command_name}" >&2
    exit 1
  fi
done

kernel_version="$(uname -r)"
workdir="$(mktemp -d "/var/tmp/aks-custom-nvidia-${DRIVER_VERSION}.XXXXXX")"
installer="${workdir}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}-grid-azure.run"
trap 'rm -rf -- "${workdir}"' EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes --no-install-recommends \
  build-essential \
  dkms \
  "linux-headers-${kernel_version}" \
  nvidia-modprobe

curl \
  --fail \
  --location \
  --retry 3 \
  --proto '=https' \
  --tlsv1.2 \
  --header "If-Match: ${DRIVER_ETAG}" \
  --output "${installer}" \
  "${DRIVER_URL}"

actual_size="$(stat --format=%s "${installer}")"
if [[ "${actual_size}" != "${DRIVER_SIZE_BYTES}" ]]; then
  echo "[ERROR] Azure GRID driver artifact size mismatch: ${actual_size}" >&2
  exit 1
fi

sh "${installer}" --check
sh "${installer}" \
  --dkms \
  --accept-license \
  -M open \
  --no-questions \
  --silent \
  --ui=none

(
  cd "${workdir}"
  apt-get download "${NVIDIA_SMI_PACKAGE}"
)
utility_package="${workdir}/nvidia-utils-595-server_595.91.07-0ubuntu0.24.04.1_$(dpkg --print-architecture).deb"
utility_extract="${workdir}/nvidia-utils"
dpkg-deb --extract "${utility_package}" "${utility_extract}"
if [[ ! -x "${utility_extract}/usr/bin/nvidia-smi" ]]; then
  echo "[ERROR] Matching NVIDIA ${DRIVER_VERSION} utility package did not contain nvidia-smi." >&2
  exit 1
fi
install -m 0755 "${utility_extract}/usr/bin/nvidia-smi" /usr/bin/nvidia-smi
if ! /usr/bin/nvidia-smi --version | grep -F "${DRIVER_VERSION}" >/dev/null; then
  echo "[ERROR] Installed nvidia-smi does not report version ${DRIVER_VERSION}." >&2
  exit 1
fi

if [[ ! -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 \
  || ! -f /usr/lib/x86_64-linux-gnu/libcuda.so.1 ]]; then
  echo "[ERROR] Installed GRID driver is missing NVML or CUDA driver libraries." >&2
  exit 1
fi
if [[ ! -x /usr/bin/nvidia-modprobe ]]; then
  echo "[ERROR] NVIDIA device-node helper is missing." >&2
  exit 1
fi

depmod -a "${kernel_version}"

installed_version="$(modinfo --field version nvidia)"
if [[ "${installed_version}" != "${DRIVER_VERSION}" ]]; then
  echo "[ERROR] Installed NVIDIA module version ${installed_version}; expected ${DRIVER_VERSION}." >&2
  exit 1
fi

module_license="$(modinfo --field license nvidia)"
if [[ "${module_license}" != "Dual MIT/GPL" ]]; then
  echo "[ERROR] Expected the Azure GRID open kernel module; found license ${module_license}." >&2
  exit 1
fi

dkms status | grep -F "nvidia/${DRIVER_VERSION}" >/dev/null || {
  echo "[ERROR] NVIDIA ${DRIVER_VERSION} is not registered with DKMS." >&2
  exit 1
}

for module_name in nvidia nvidia_uvm nvidia_modeset nvidia_drm; do
  module_path="$(modinfo --field filename "${module_name}")"
  if [[ ! -f "${module_path}" ]]; then
    echo "[ERROR] NVIDIA module file is missing: ${module_name} (${module_path})." >&2
    exit 1
  fi

  module_version="$(modinfo --field version "${module_path}")"
  if [[ "${module_version}" != "${DRIVER_VERSION}" ]]; then
    echo "[ERROR] ${module_name} version ${module_version}; expected ${DRIVER_VERSION}." >&2
    exit 1
  fi
  module_vermagic="$(modinfo --field vermagic "${module_path}")"
  if [[ "${module_vermagic}" != "${kernel_version} "* ]]; then
    echo "[ERROR] ${module_name} vermagic ${module_vermagic}; expected kernel ${kernel_version}." >&2
    exit 1
  fi
done

install -d -m 0755 /etc/modules-load.d
cat > "${MODULES_LOAD_CONFIG}" <<'EOF'
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF
chmod 0644 "${MODULES_LOAD_CONFIG}"
update-initramfs -u -k "${kernel_version}"

# The base image's marker describes its managed CUDA driver, not this replacement GRID driver.
# Leaving it behind makes AKS's opted-out-driver cleanup delete the custom modules and tools.
if [[ -f "${AKS_GPU_PREBAKE_MARKER}" ]]; then
  rm -- "${AKS_GPU_PREBAKE_MARKER}"
  echo "[INFO] Removed stale AKS managed-driver prebake marker."
fi

cat > /etc/aks-custom-nvidia-driver <<EOF
driver_version=${DRIVER_VERSION}
driver_flavor=azure-grid-vgpu
artifact_url=${DRIVER_URL}
artifact_etag=${DRIVER_ETAG}
nvidia_smi_package=${NVIDIA_SMI_PACKAGE}
kernel_version=${kernel_version}
module_type=open
modules_load_config=${MODULES_LOAD_CONFIG}
nvidia_modprobe_version=$(dpkg-query -W -f='${Version}' nvidia-modprobe)
EOF
chmod 0644 /etc/aks-custom-nvidia-driver

echo "[INFO] Installed Microsoft-redistributed Azure GRID vGPU ${DRIVER_VERSION} open kernel module with DKMS."
echo "[INFO] NVIDIA modules will load through ${MODULES_LOAD_CONFIG}; no recovery DaemonSet is required."
echo "[INFO] No AKS provisioning script or kubelet service was modified."
