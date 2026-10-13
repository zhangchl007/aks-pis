# PIS customization scripts 说明

本目录有两种用途不同的 PIS JSON：审阅包文件只复制脚本；RTX 文件在镜像构建阶段安装 Microsoft 为 NCv6 RTX PRO 6000 BSE 发布的 Azure GRID vGPU driver。

## 文件对应关系

| 文件 | 用途 | 执行内容 |
| --- | --- | --- |
| [`pis-scripts.json`](../azure-init-review/pis-scripts.json) | 原有审阅包的 PIS customization；供旧 PIS version 和原工作流继续使用 | 把审阅脚本作为静态文件复制到 `/opt/azure-init-review`；不执行它们 |
| [`pis-scripts-rtx6000.json`](../azure-init-review/pis-scripts-rtx6000.json) | RTX 自定义驱动 PIS customization | 在 `NodeImageBuildTime` 安装 Microsoft-redistributed Azure GRID vGPU driver `595.91.07` |
| [`rtx6000-driver-install.sh`](../azure-init-review/rtx6000-driver-install.sh) | RTX JSON 中 Bash 脚本的可读源文件 | 下载并校验 Azure GRID vGPU artifact，以 DKMS 安装 open kernel module |
| [`build_azure_init_pis.py`](../tools/build_azure_init_pis.py) | 旧审阅包 JSON 生成器 | 校验审阅包 checksums 和 shell 语法，生成旧 `pis-scripts.json` |
| [`build_rtx6000_pis.py`](../tools/build_rtx6000_pis.py) | RTX driver JSON 生成器 | 从安装脚本生成 RTX JSON，并检查 Bash 语法 |
| [`gpu-operator-rtx6000-values.yaml`](../azure-init-review/gpu-operator-rtx6000-values.yaml) | GPU Operator 实测配置 | 禁用 driver 安装，使用 PIS staged driver root，启用 Toolkit/device plugin 和 file-based runtime config |
| [`rtx6000-cuda-smoke-job.yaml`](../azure-init-review/rtx6000-cuda-smoke-job.yaml) | 真实 GPU 计算验证 | 申请一个 GPU，通过 CUDA Driver API 运行 PTX kernel 并逐项校验 65,536 个结果 |

## 为什么旧 JSON 看起来像乱码

旧 `pis-scripts.json` 把 8 个审阅文件转成 Base64，再嵌入 `script` 字段中的 here-document。JSON 里的 `\n` 是换行转义，长串 Base64 是文件内容编码，不是加密。旧脚本会在镜像构建时解码并校验文件，但不会运行它们。

RTX JSON 不再嵌入这些 Base64 文件。当前内嵌的是可读的驱动安装 Bash 脚本；需要查看时，直接读 [`rtx6000-driver-install.sh`](../azure-init-review/rtx6000-driver-install.sh)，或运行：

```bash
jq -r '.[0].script' azure-init-review/pis-scripts-rtx6000.json
```

## RTX 自定义驱动安装逻辑

[`rtx6000-driver-install.sh`](../azure-init-review/rtx6000-driver-install.sh) 使用 Microsoft-hosted Azure GRID vGPU runfile，并执行以下步骤：

1. 在 Ubuntu x86-64 环境安装当前 kernel 对应 headers、DKMS 和 build dependencies。
2. 从 Microsoft 下载并固定 Azure GRID vGPU `595.91.07` artifact；要求 HTTPS ETag 匹配且文件大小正确，并运行 runfile 自带的 `--check`。
3. 按 Azure NCv6 指引以 open kernel module 和 DKMS 安装；验证 `nvidia`、`nvidia_uvm`、`nvidia_modeset`、`nvidia_drm` 模块文件、driver version 和 kernel vermagic。
4. 将 kernel modules 归档到 `/opt/aks-custom-nvidia-driver/modules/<kernel>`，并把恢复 helper 放到 `/usr/local/sbin/aks-custom-nvidia-restore-modules`。节点 `Ready` 后，由 [`rtx6000-module-restore-daemonset.yaml`](../azure-init-review/rtx6000-module-restore-daemonset.yaml) 在目标 RTX pool 上运行该 helper；这避免修改 AKS 管理的 kubelet systemd unit。
5. 把 GRID 用户态 libraries 与版本匹配的 `nvidia-smi` 放在 `/opt/aks-custom-nvidia-driver/root`，供节点检查和后续 runtime 集成测试使用。`nvidia-smi` 从匹配的 Ubuntu utility package 中只提取 binary，不安装 Ubuntu NVIDIA kernel driver，也不覆盖 GRID libraries；这不代表 GPU Operator 或容器 runtime 已配置完成。
6. 在 `/etc/aks-custom-nvidia-driver` 记录 artifact、kernel、module archive、restore helper 和 driver root。

Azure 文档将 NCv6 RTX PRO 6000 BSE 的 vGPU20.2 (`595.91.07`) 列为受支持的 GRID driver。通用 NVIDIA runfile 即使版本号相同，也不是该 Azure vGPU package；Ubuntu `nvidia-driver-595-server` 同样不包含 Azure GRID vGPU 支持。此前试验和根因详见 [runbook 实测](./azure-init-review-runbook.md#78-rtx-pis-自定义-driver-canary-实测与修正)。

安装器不安装 CUDA Toolkit、Kubernetes NVIDIA device plugin 或 GPU Operator，也不运行性能测试。GPU Pod 调度还需要单独配置 device plugin；不能将“驱动已安装”等同于“GPU 已可调度”。

## AKS node pool 必须关闭自动驱动安装

自定义驱动 PIS 必须与 AKS 默认 GPU driver 安装互斥。创建 RTX canary pool 时应同时指定：

```bash
--enable-managed-gpu false \
--gpu-driver None \
```

`--gpu-driver None` 阻止 AKS 在节点上安装默认 NVIDIA driver；`--enable-managed-gpu false` 禁用包含驱动和 GPU stack 的 managed profile。不要在此自管驱动测试池使用 `--enable-managed-gpu true`，否则 AKS 会继续管理/安装驱动，与 PIS 自定义 driver 测试目标冲突。AKS 文档说明 driver/profile 在 pool 创建时确定；变更时需创建新 pool。

AKS 现有的 `rtxspot` 是 managed GPU 对照池，并非自定义驱动测试结果。保留它作为 baseline，不要将它的 `nvidia-smi` 输出误认为 PIS 自定义 driver 已验证。

## 生成和检查

旧审阅文件只用旧生成器：

```bash
python3 tools/build_azure_init_pis.py
```

RTX 自定义驱动脚本只用 RTX 生成器：

```bash
python3 tools/build_rtx6000_pis.py
```

验证两个 JSON 和 RTX Bash 语法：

```bash
python3 -m json.tool azure-init-review/pis-scripts.json >/dev/null
python3 -m json.tool azure-init-review/pis-scripts-rtx6000.json >/dev/null
jq -r '.[0].script' azure-init-review/pis-scripts-rtx6000.json | bash -n
```

修改 RTX 脚本后重建 JSON，并创建新的不可变 PIS version；现有 PIS version 不会因重新生成本地 JSON 而变化。

## 当前验证结果

- PIS version：`custom-azure-grid-595.91.07-v5-postready-restore`，预置 Azure GRID `595.91.07`，不修改 kubelet。
- 节点 Ready 后，由恢复 DaemonSet 加载四个 NVIDIA 模块；首次启动和一次重启后的模块恢复均通过。
- GPU Operator v26.7.2 / Toolkit v1.20.1 已安装，GPU capacity/allocatable 为 1/1。
- Operator CUDA validator 与独立 GPU Job 的真实计算均通过；性能对照和长期稳定性尚未测试。

## GPU Operator 配置

保留 PIS 安装的 driver，由 GPU Operator 管理 Toolkit 和 device plugin。已验证的关键设置为：

```yaml
driver:
  enabled: false
hostPaths:
  driverInstallDir: /opt/aks-custom-nvidia-driver/root
toolkit:
  enabled: true
  env:
    - name: RUNTIME_CONFIG_SOURCE
      value: file
devicePlugin:
  enabled: true
```

`hostPaths.driverInstallDir` 指向 PIS 安装器归档的匹配版本 driver userspace，使 Operator validator 和 Toolkit 能发现并注入 libraries 与 `nvidia-smi`；这个参数不负责安装 kernel driver。完整配置还包含 Spot toleration、RTX pool 的 NFD worker selector、`mig.strategy=single`，并关闭 MIG manager（不改变 Azure 提供的 MIG partition）和 DCGM exporter（本次只验收调度与计算）。完整文件见 [`gpu-operator-rtx6000-values.yaml`](../azure-init-review/gpu-operator-rtx6000-values.yaml)；安装及 GPU Job 命令见 [runbook](./azure-init-review-runbook.md#78-rtx-pis-自定义-driver-canary-实测与修正)。

## 官方资料

- [AKS GPU 节点：自管 NVIDIA 驱动](https://learn.microsoft.com/en-us/azure/aks/use-nvidia-gpu)
- [AKS managed GPU 节点及 driver 管理模式](https://learn.microsoft.com/en-us/azure/aks/aks-managed-gpu-nodes)
- [AKS NVIDIA GPU Operator](https://learn.microsoft.com/en-us/azure/aks/nvidia-gpu-operator)
- [Azure N-series Linux GRID driver setup](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/n-series-driver-setup)
- [NC RTX PRO 6000 Blackwell v6 series overview](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/gpu-accelerated/nc-rtxpro6000-bse-v6-series-overview)
- [AKS Prepared Image Specification 概述](https://learn.microsoft.com/en-us/azure/aks/prepared-image-specification-overview)
