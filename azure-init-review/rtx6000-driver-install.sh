#!/usr/bin/env bash
set -Eeuo pipefail

readonly DRIVER_VERSION="595.91.07"
readonly DRIVER_URL="https://download.microsoft.com/download/a7cb6d36-3bbc-43d6-9e88-e0842e6f9ab9/NVIDIA-Linux-x86_64-${DRIVER_VERSION}-grid-azure.run"
readonly DRIVER_ETAG='"0x5CC7884478050ADF7A438E998A6E37D3AD7EDB092C8835A0F88F79D61F790107"'
readonly DRIVER_SIZE_BYTES="429294357"
readonly NVIDIA_SMI_PACKAGE="nvidia-utils-595-server=595.91.07-0ubuntu0.24.04.1"
readonly DRIVER_ROOT="/opt/aks-custom-nvidia-driver/root"
readonly MODULE_ARCHIVE_ROOT="/opt/aks-custom-nvidia-driver/modules"
readonly RESTORE_SCRIPT="/usr/local/sbin/aks-custom-nvidia-restore-modules"

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

for command_name in apt-get awk curl depmod dpkg dpkg-deb dkms find install modinfo modprobe mknod systemctl; do
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
  "linux-headers-${kernel_version}"

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

install -d -m 0755 \
  "${DRIVER_ROOT}/usr/bin" \
  "${DRIVER_ROOT}/usr/lib/x86_64-linux-gnu" \
  "${DRIVER_ROOT}/lib/x86_64-linux-gnu"
cp -pL /usr/bin/nvidia-smi "${DRIVER_ROOT}/usr/bin/nvidia-smi"
for library_dir in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu; do
  case "${library_dir}" in
    /usr/*) driver_root_path="usr/lib/x86_64-linux-gnu" ;;
    *) driver_root_path="lib/x86_64-linux-gnu" ;;
  esac
  find "${library_dir}" -maxdepth 1 \
    \( -name 'libnvidia*.so*' -o -name 'libcuda.so*' -o -name 'libnvcuvid.so*' \) \
    -exec cp -pL -t "${DRIVER_ROOT}/${driver_root_path}" {} +
done
if [[ ! -f "${DRIVER_ROOT}/lib/x86_64-linux-gnu/libnvidia-ml.so.1" \
  || ! -f "${DRIVER_ROOT}/usr/lib/x86_64-linux-gnu/libcuda.so.1" ]]; then
  echo "[ERROR] Staged GRID driver root is missing NVML or CUDA driver libraries." >&2
  exit 1
fi
if ! LD_LIBRARY_PATH="${DRIVER_ROOT}/lib/x86_64-linux-gnu:${DRIVER_ROOT}/usr/lib/x86_64-linux-gnu" \
  "${DRIVER_ROOT}/usr/bin/nvidia-smi" --version | grep -F "${DRIVER_VERSION}" >/dev/null; then
  echo "[ERROR] Staged nvidia-smi cannot load the GRID ${DRIVER_VERSION} libraries." >&2
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

module_archive="${MODULE_ARCHIVE_ROOT}/${kernel_version}"
install -d -m 0755 "${module_archive}"
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

  install -m 0644 "${module_path}" "${module_archive}/$(basename "${module_path}")"
done

cat > "${RESTORE_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /etc/aks-custom-nvidia-driver
readonly DRIVER_VERSION="${driver_version}"
readonly kernel_version="$(uname -r)"
readonly module_archive="/opt/aks-custom-nvidia-driver/modules/${kernel_version}"
readonly module_dir="/lib/modules/${kernel_version}/updates/dkms"

if [[ ! -d "${module_archive}" ]]; then
  echo "[ERROR] No archived NVIDIA modules for running kernel ${kernel_version}: ${module_archive}" >&2
  exit 1
fi

install -d -m 0755 "${module_dir}"
for module_name in nvidia nvidia-uvm nvidia-modeset nvidia-drm; do
  module_file="$(find "${module_archive}" -maxdepth 1 -type f \
    \( -name "${module_name}.ko" -o -name "${module_name}.ko.*" \) -print -quit)"
  if [[ -z "${module_file}" ]]; then
    echo "[ERROR] Archived module is missing: ${module_name}." >&2
    exit 1
  fi
  module_vermagic="$(modinfo --field vermagic "${module_file}")"
  if [[ "${module_vermagic}" != "${kernel_version} "* ]]; then
    echo "[ERROR] ${module_name} vermagic ${module_vermagic}; expected kernel ${kernel_version}." >&2
    exit 1
  fi
  install -m 0644 "${module_file}" "${module_dir}/$(basename "${module_file}")"
done

depmod -a "${kernel_version}"
modprobe nvidia
modprobe nvidia_modeset
modprobe nvidia_uvm
modprobe nvidia_drm

if [[ ! -c /dev/nvidia-uvm ]]; then
  uvm_major="$(awk '$2 == "nvidia-uvm" { print $1; exit }' /proc/devices)"
  if [[ -z "${uvm_major}" ]]; then
    echo "[ERROR] The loaded NVIDIA UVM module did not register a device major." >&2
    exit 1
  fi
  mknod -m 0666 /dev/nvidia-uvm c "${uvm_major}" 0
fi
if [[ ! -c /dev/nvidia-uvm-tools ]]; then
  uvm_major="$(awk '$2 == "nvidia-uvm" { print $1; exit }' /proc/devices)"
  if [[ -z "${uvm_major}" ]]; then
    echo "[ERROR] The loaded NVIDIA UVM module did not register a device major." >&2
    exit 1
  fi
  mknod -m 0666 /dev/nvidia-uvm-tools c "${uvm_major}" 1
fi

if [[ "$(modinfo --field version nvidia)" != "${DRIVER_VERSION}" ]] \
  || [[ "$(modinfo --field version nvidia_uvm)" != "${DRIVER_VERSION}" ]]; then
  echo "[ERROR] Restored NVIDIA modules do not match driver ${DRIVER_VERSION}." >&2
  exit 1
fi

echo "[INFO] Restored and loaded NVIDIA ${DRIVER_VERSION} kernel modules for ${kernel_version}."
EOF
chmod 0755 "${RESTORE_SCRIPT}"

cat > /etc/aks-custom-nvidia-driver <<EOF
driver_version=${DRIVER_VERSION}
driver_flavor=azure-grid-vgpu
artifact_url=${DRIVER_URL}
artifact_etag=${DRIVER_ETAG}
nvidia_smi_package=${NVIDIA_SMI_PACKAGE}
kernel_version=${kernel_version}
module_type=open
module_archive=${module_archive}
module_restore_helper=${RESTORE_SCRIPT}
driver_root=${DRIVER_ROOT}
EOF
chmod 0644 /etc/aks-custom-nvidia-driver

echo "[INFO] Installed Microsoft-redistributed Azure GRID vGPU ${DRIVER_VERSION} open kernel module with DKMS."
echo "[INFO] Archived NVIDIA kernel modules under ${module_archive} and staged ${RESTORE_SCRIPT}."
echo "[INFO] No kubelet service or systemd startup hook was modified; runtime module restoration is not configured."
