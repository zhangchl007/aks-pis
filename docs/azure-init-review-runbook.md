# Runbook：将 `azure-init-review` 审阅包打入 AKS PIS 镜像

## 1. 目的与安全边界

本 runbook 将 `azure-init-review` 中的主初始化脚本、子脚本、审阅说明和校验清单作为**静态文件**复制到 AKS PIS prepared image：

```text
/opt/azure-init-review/
```

PIS customization 只解码、校验和安装这些文件；**不会 source、执行或下载其中任何初始化脚本**。这一区分是强制安全边界：此审阅包不是可直接部署的初始化版本。

源码包以脱敏占位值展示原脚本结构，不能直接作为部署配置。[README.md](../azure-init-review/README.md) 说明了提取与验证范围；当前 PIS bundle 只复制审阅文件，不执行包内初始化脚本。

### 每日重建 node pool 的实测结论

对每天删除并新建节点池的工作流，**不要把 PIS 作为默认路径**。PIS 会在关联它的 node pool create/update 流程中准备镜像；每次新建池都可能再次触发这项准备。Microsoft Learn 将其收益定位在镜像准备后的重复 scale-out，并指出初次 create/update 会因构建镜像而更慢。

在同一隔离 AKS canary 集群中，以相同的测试 VM SKU 和 Ubuntu 配置做了实测：

| 测试 | AKS operation 时间 | 节点结果 |
| --- | ---: | --- |
| PIS 池，第 1 次 | 18 分 20 秒 | `Succeeded`，节点 `Ready` |
| PIS 池，第 2 次 | 17 分 02 秒 | `Succeeded`，节点 `Ready` |
| PIS 池，仅 `echo` 简单脚本 | 18 分 00 秒 | `Succeeded`，节点 `Ready` |
| 普通 Ubuntu 池，不关联 PIS | 1 分 19 秒 | `Succeeded`，节点 `Ready` |

第二次 PIS 测试中，customization 和 generalize Run Command 各约 **22 秒**。额外创建的简单脚本对照中，`echo PIS_NOOP_OK` 用时约 **22.8 秒**，generalize 约 **22.9 秒**；builder VM deallocate 到目标 node pool VMSS 开始创建之间相隔 **13 分 16 秒**，整个 AKS operation 用时 **18 分钟**，节点随后 `Ready`。因此简化脚本没有显著缩短端到端耗时，脚本复杂度不是主因。

每次新建 PIS 池都会产生临时 builder VMSS；普通池对照在同集群、同 SKU 下 79 秒完成。因此本工作流的可操作根因是：**每天新建池重复进入 PIS 镜像准备路径**。本审阅包只有静态文件复制，没有容器镜像预缓存或其他能补偿该成本的用途。

Activity Log 只记录了 build VM、Run Command 和目标 VMSS 等 ARM 操作；PIS 服务端镜像准备的内部子阶段未暴露，因此不能将 deallocate 后约 12–13 分钟的等待进一步断言为某个特定快照/捕获动作。Microsoft Learn 没有给出初次 PIS 构建的分钟数或时长 SLA；它只说明初次 node pool create/update 会先构建镜像，因此会耗时更长。这个服务端子阶段是否达到产品预期，公开资料无法判定；但该未知项不影响当前修复决策：日常新建池应不使用 PIS。

## 2. 评审结论：不能将原主脚本作为 PIS build-time 脚本执行

`NodeImageBuildTime` 脚本在准备镜像的 build node 上运行，而不是在将来每一台目标节点上运行。原初始化流程包含节点启动时及环境相关的操作；若直接执行，不但无法保证目标节点上的行为，还可能令镜像构建失败或固化错误配置。

| 严重性 | 脚本/逻辑 | 风险及处理 |
| --- | --- | --- |
| **阻断** | [`k8s_init.azure.redacted.sh`](../azure-init-review/k8s_init.azure.redacted.sh)：`disk_init_azure`、`azure_mount_disk` | 查找 LUN 0/1，并在无文件系统时运行 `mkfs.xfs`，再按磁盘大小映射 `/cce`、`/data`。PIS build node 的磁盘不是目标 AKS node pool 的数据盘；执行可能失败，或格式化非预期磁盘。只把源文件打包，不执行。磁盘初始化应由目标节点上的受控生命周期机制完成，并先验证 LUN/资源盘/OS 盘识别与数据保护。 |
| **阻断** | [`init_user.sh`](../azure-init-review/initialization/scripts/init_user.sh)：`user_init`、`addSudo` | 会删除同名用户并重建；部分用户会被加入 sudo/wheel，并可能配置无密码 sudo；authorized_keys 依赖远程下载。镜像构建时执行会把账户状态、sudoers 和密钥绑定到错误环境。 |
| **高** | [`k8s_init.azure.redacted.sh`](../azure-init-review/k8s_init.azure.redacted.sh)：`env_init`、`dns_init`；[`dns_update_workspace.sh`](../azure-init-review/initialization/scripts/dns_update_workspace.sh) | 覆盖 `/etc/resolv.conf`、停用 `systemd-resolved`，并可能对 resolver 文件设置 immutable 属性；DNS 来自 workspace/CMDB 和内部网络。把构建环境的 DNS 配置烘焙进节点镜像会造成节点 DNS 与 AKS 网络环境不一致，也可能妨碍后续配置管理。 |
| **高** | 主脚本及其子脚本中的 `curl ... | bash`、HTTP `wget` | 以高权限从未加密 HTTP 下载并立即执行远程内容，没有内容固定或签名校验；存在传输篡改和远程内容变化风险。当前审阅副本的地址均为占位地址，功能不可用。生产化前应改为批准的 HTTPS 来源、不可变版本和独立完整性/签名校验；不要把令牌或凭据写入 PIS `script`。 |
| **高** | [`ntpdate_set.sh`](../azure-init-review/initialization/scripts/ntpdate_set.sh)、[`ntpdate_eu_set.sh`](../azure-init-review/initialization/scripts/ntpdate_eu_set.sh) | 会安装/配置 chrony、覆盖或修改时间源配置、重启/启用服务并清理旧 cron。NTP 源和配置文件位置依赖 OS/区域；海外与国内分支由运行时参数选择，不能在 PIS build node 上安全推断。 |
| **高** | [`del_log.sh`](../azure-init-review/scripts/del_log.sh) | 会删除多个系统/应用日志目录中匹配的旧文件并执行 journal vacuum；还会直接检查/修改 root cron 文件。必须先确认目标目录、保留策略、cron 管理方式和最小权限。不能为了打包而执行。 |
| **高** | 主脚本 `env_init` / `service_init` | 停止并禁用 firewalld、修改 SELinux 配置、改变时区、停用 `node_exporter`。这些变更影响节点安全、时间语义与监控，不应作为未评审的镜像副作用。 |
| **中** | 主脚本错误传播 | 主流程没有统一的 `set -Eeuo pipefail`；`curl/wget | bash`、服务控制等失败后可能继续运行或记录成功，难以判断初始化是否完整。若将来要支持执行，须重构为显式参数校验、错误处理、日志、幂等和失败恢复。 |
| **中** | OS/工具假设 | 子脚本包含 Ubuntu/Debian 与 CentOS/Rocky 分支、多个 chrony 配置路径及系统工具假设。必须针对目标 AKS OS SKU 和版本分别验证；不能把“bash -n 通过”当作运行兼容性证明。 |

此外，Azure 官方 PIS 文档指出，customization script 失败可能导致 image build 或 scale-up 失败；脚本和容器镜像同时使用时，脚本先运行，再进行镜像缓存。更多 PIS 约束见[官方文档](https://learn.microsoft.com/en-us/azure/aks/prepared-image-specification-overview)。

### 2.1 DNS / NTP 对 AKS 托管节点的合规性与风险评估

**结论：当前 PIS bundle 不会应用这些 DNS/NTP 改动；如果把审阅包中的原主脚本直接运行在 AKS agent node 上，则不符合推荐的 AKS 节点管理方式，应视为高风险、未获 AKS 支持确认的 host-level customization，不应部署。** 本节是对源码行为和 Microsoft Learn 支持边界的静态评估，不表示已在生产节点执行或验证了这些脚本。

Microsoft 的 AKS [support policies](https://learn.microsoft.com/en-us/azure/aks/support-policies#shared-responsibility) 要求通过 Kubernetes-native 机制管理节点改动，并说明直接修改 agent node 会影响 AKS 支持范围；[custom node configuration](https://learn.microsoft.com/en-us/azure/aks/custom-node-configuration) 只支持文档列出的 OS / kubelet 参数，超出范围应使用文档建议的机制，不要靠启动脚本随意更改受管节点 OS。细节仍需按使用的 AKS 版本、OS SKU 和具体配置与 Microsoft Support 确认。

| 项目 | 源码实际行为 | 合规性判断 | 主要风险 |
| --- | --- | --- | --- |
| 节点 DNS | [`k8s_init.azure.redacted.sh`](../azure-init-review/k8s_init.azure.redacted.sh) 将 DNS 写入 `/etc/resolv.conf`；[`dns_update_workspace.sh`](../azure-init-review/initialization/scripts/dns_update_workspace.sh) 在 Ubuntu/Debian 上停止并禁用 `systemd-resolved`、删除其 resolver 文件链接/文件、从 CMDB 写入 nameserver，并对 `/etc/resolv.conf` 设置 immutable (`chattr +i`)。 | **不建议 / 高风险。** 直接改 agent node resolver、禁用系统 resolver、锁定文件都不属于 AKS 的常规 DNS 配置入口；源码没有证明该做法在 AKS 受支持。 | 可能破坏节点 bootstrap、控制面/注册表/镜像仓库等名称解析和 Pod 的上游 DNS；VNet/Private DNS 变化后节点文件不会自动跟进；规模扩缩或升级后的节点可能配置不一致；immutable 属性可能阻止 OS/AKS 管理流程更新 resolver。 |
| 节点 NTP | [`ntpdate_set.sh`](../azure-init-review/initialization/scripts/ntpdate_set.sh) 与 [`ntpdate_eu_set.sh`](../azure-init-review/initialization/scripts/ntpdate_eu_set.sh) 会修改 chrony 配置、注释现有 `server` / `pool` 行、追加按区域选定的内部时间源并重启/启用服务；也会清理匹配旧时间源的 root cron 项。 | **不建议 / 高风险。** 对受管节点替换 OS 默认 time-sync 配置属于未验证的 host-level customization；没有源代码证据表明该自定义源是 AKS 要求。 | endpoint 不可达、DNS 错误、UDP/123 被阻断或 unit/config 路径与 Ubuntu 版本不符时，节点可能失去可靠校时；脚本对实际同步状态的失败处理不足。时钟漂移会影响 TLS 证书校验、令牌有效期、日志关联及分布式任务时序。 |
| 示例地址与参数 | 当前脱敏副本中的 `192.0.2.x` 属于文档示例地址，`.example.invalid` 为不可解析占位域名；主脚本还把 `is_i8n` 参数作为国内/海外 NTP 分支依据，DNS 内容依赖 CMDB 返回值。 | **不可作为生产配置。** 脱敏副本不能证明生产中的 DNS/NTP 地址有效、获批或可路由。 | 如照此副本执行，DNS 初始 nameserver 与用于探测源 IP 的地址不可用于生产；真实脚本即使替换占位符，也仍须验证每个返回地址和环境分支，不能把 CMDB 响应直接当作可信 DNS 配置。 |
| 其他主机设置 | 主脚本还会停止 firewalld、修改 SELinux 配置、强制将时区设为 `Asia/Shanghai`，并停用 `node_exporter`。 | **未通过受管节点配置审核。** 这类节点 OS/service/security posture 变更同样不应作为未批准的通用 AKS init 脚本部署。 | 防火墙或 SELinux 关闭会降低节点防护；停用 exporter 会造成监控盲区；固定本地时区可能造成日志/运维时间解释不一致。时区不是 NTP，也不能修复时钟同步。 |

Microsoft 的 [AKS DNS 概念文档](https://learn.microsoft.com/en-us/azure/aks/dns-concepts)描述了 Pod DNS 查询经 CoreDNS 并转发到上游的路径；Azure DNS 地址 `168.63.129.16` 还承担 Azure 虚拟网络 DNS 等平台服务，Azure 要求防火墙策略不要误拦截所需的平台通信（见 [168.63.129.16 文档](https://learn.microsoft.com/en-us/azure/virtual-network/what-is-ip-address-168-63-129-16)）。这不是说每个 AKS 环境都必须把该地址手工写入 `/etc/resolv.conf`；DNS server 应从 AKS / VNet 当前配置确认。Azure Linux VM 时间同步文档指出，时间服务通常由 `ntpd` 或 `chronyd` 提供，并说明 Azure host 常是可靠的时间源（见 [Linux VM time sync](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/time-sync)）；不可据此推断每个 AKS OS SKU 或自定义镜像使用完全相同的 chrony 配置。

**当前交付物的实际影响：** PIS 中的 [`pis-scripts.json`](../azure-init-review/pis-scripts.json) 在 `NodeImageBuildTime` 仅将审阅文件复制到 `/opt/azure-init-review`、校验并以 `0644` 保存；不会调用或 `source` 主脚本及 DNS/NTP 子脚本。因此这些 DNS/NTP 修改目前只是被打包用于审阅，没有应用到 PIS canary 节点。此前在 canary 节点验证的是文件 checksum 和 `bash -n`，**不是** DNS 变更、NTP 同步或脚本运行兼容性验证。

#### 如确有自定义 DNS / NTP 需求

1. **DNS：** 先确定是节点出站解析、Pod 外部域名解析还是 Kubernetes service 域名解析。节点上游解析优先按 [AKS 自定义 DNS 指引](https://learn.microsoft.com/en-us/azure/aks/dns-concepts)配置 VNet / subnet DNS，并确认自定义解析器对 AKS 节点可达、能转发 Azure/Private DNS 所需区域，且支持 UDP 与 TCP 53；Pod 转发策略使用 AKS 支持的 CoreDNS / LocalDNS 配置方式。不要直接覆盖 `/etc/resolv.conf`、禁用 `systemd-resolved` 或设置 immutable。
2. **NTP：** 先只读检查目标 AKS OS image 的当前服务、同步状态和 source；不要因为 Ubuntu VM 上存在 chrony 就替换它，也不要因“集群有 NTP”而假设任何自定义镜像都配置正确。若合规要求强制企业 NTP，先确认 AKS 支持边界、时间源路由/防火墙、DNS 依赖、区域一致性和同步监控，并取得平台团队/Microsoft 对所选节点配置方式的确认；保留原始配置和可回退方案。
3. **静态只读检查：** 在获批的 canary 节点上查看 `readlink -f /etc/resolv.conf`、`systemctl is-active systemd-resolved chrony chronyd`、`timedatectl show -p NTPSynchronized -p TimeUSec`、`chronyc tracking` 与 `chronyc sources -v`（仅在相应工具存在时）。不要运行初始化脚本；分享诊断输出前先脱敏 DNS/NTP 地址和内部域名。
4. **验收标准：** 节点重新创建、scale-out 和升级后配置仍一致；节点与 Pod 分别能解析 AKS API/镜像仓库、Azure/Private DNS 与预期服务名；NTP 同步为正常且 source 符合审批；无 CoreDNS/LocalDNS、节点注册、镜像拉取、证书验证或时间告警。仅 `bash -n` 或看到配置文件存在不构成运行合规性验收。

## 3. 产物与内容

生成的 [`pis-scripts.json`](../azure-init-review/pis-scripts.json) 使用一个 `Bash` / `NodeImageBuildTime` customization script。它会：

1. 要求 root，并确认需要的基础工具存在。
2. 将审阅包内容写入临时目录。
3. 使用包内 `SHA256SUMS` 校验 README 和六个 shell 文件。
4. 将内容以 **`0644`** 权限复制到 `/opt/azure-init-review`，不允许被误当成可直接执行的程序。
5. 如果目标目录已有完全相同的内容，则不做修改；如果目录内容不同，则安全失败，不覆盖现有文件。
6. 写入 `BUNDLE-MANIFEST.txt`，记录 bundle ID 和“只打包、不执行”的约束。

包内 SHA256 清单用于发现非预期内容漂移；它与文件一同存放，**不是**发布者身份认证、数字签名或供应链证明。

## 4. 生成并检查 PIS JSON

在工作区根目录运行。生成器只读取 `azure-init-review` 中明确列出的输入；生成前会校验 SHA256 清单，并对六个脚本和最终 PIS customization script 运行 `bash -n`。

```bash
python3 tools/build_azure_init_pis.py
```

默认输出：

```text
azure-init-review/pis-scripts.json
```

生成器会拒绝覆盖源文件或生成器本身。也可以指定其他输出位置：

```bash
python3 tools/build_azure_init_pis.py \
  --output /tmp/azure-init-review-pis-scripts.json
```

检查 JSON 结构及 PIS 参数：

```bash
python3 - <<'PY'
import json
from pathlib import Path

path = Path("azure-init-review/pis-scripts.json")
items = json.loads(path.read_text(encoding="utf-8"))
assert len(items) == 1
item = items[0]
assert item["name"] == "azure-init-review-bundle"
assert item["scriptType"] == "Bash"
assert item["executionPoint"] == "NodeImageBuildTime"
assert item["postScriptAction"] == "None"
assert "bash /opt/azure-init-review/" not in item["script"]
assert "No bundled initialization script was executed." in item["script"]
print(f"JSON OK; script bytes={len(item['script'].encode('utf-8'))}")
PY
```

将 JSON 与源码一同纳入受控变更审核。不要把生成的 JSON 或脚本内容粘贴到公开位置；虽然当前包已脱敏，未来源文件可能包含内部信息。

## 5. 创建 PIS 版本

先设置目标 Azure 资源参数。PIS 与要引用它的 node pool 必须在同一区域；订阅、区域和 VM SKU 配额也须符合实际环境要求。

```bash
export RESOURCE_GROUP="<resource-group>"
export PIS_NAME="azure-init-review"
export PIS_VERSION="review-bundle-v1"
export LOCATION="<node-pool-region>"

az aks prepared-image-specification create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PIS_NAME}" \
  --version "${PIS_VERSION}" \
  --location "${LOCATION}" \
  --customization-scripts @azure-init-review/pis-scripts.json
```

查看 PIS 版本资源并取得完整资源 ID：

```bash
az aks prepared-image-specification version show \
  --resource-group "${RESOURCE_GROUP}" \
  --pis-name "${PIS_NAME}" \
  --name "${PIS_VERSION}" \
  --output jsonc

export PIS_VERSION_ID="$(
  az aks prepared-image-specification version show \
    --resource-group "${RESOURCE_GROUP}" \
    --pis-name "${PIS_NAME}" \
    --name "${PIS_VERSION}" \
    --query id \
    --output tsv
)"

test -n "${PIS_VERSION_ID}"
printf '%s\n' "${PIS_VERSION_ID}"
```

**版本资源存在不代表镜像构建已完成。** 按下一步将版本关联到一次性/专用测试节点池，并监控 node pool provisioning 状态。

### 5.1 授予 AKS identity 读取 PIS 的权限

在现有集群上关联 PIS 时，AKS 服务端需要集群 identity 读取 PIS。缺少权限时，节点池创建会失败并返回 `ResourceMissingPermissionError`，指出缺少 `Microsoft.ContainerService/preparedImageSpecifications/read`。官方操作页未把这项跨资源 RBAC 前置条件单独列出；因此，在创建测试节点池前，检查 AKS system-assigned identity 是否能读取 PIS。

将 `Reader` 仅授予到 PIS 资源范围，不要为此测试给 identity 增加整个订阅或资源组的角色：

```bash
export PIS_RESOURCE_SCOPE="/subscriptions/<subscription-id>/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerService/preparedImageSpecifications/${PIS_NAME}"
export AKS_IDENTITY_PRINCIPAL_ID="$(
  az aks show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --query identity.principalId \
    --output tsv
)"

test -n "${AKS_IDENTITY_PRINCIPAL_ID}"

HAS_PIS_READER="$(
  az role assignment list \
    --scope "${PIS_RESOURCE_SCOPE}" \
    --include-inherited \
    --query "[?principalId=='${AKS_IDENTITY_PRINCIPAL_ID}' && roleDefinitionName=='Reader'] | length(@)" \
    --output tsv
)"

if [[ "${HAS_PIS_READER}" == "0" ]]; then
  az role assignment create \
    --assignee-object-id "${AKS_IDENTITY_PRINCIPAL_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role Reader \
    --scope "${PIS_RESOURCE_SCOPE}"
fi
```

角色分配可能需要时间传播；之后再创建节点池。操作者必须有权创建角色分配。若企业策略不允许授予此权限，停止操作并请资源所有者按批准的最小权限配置处理；不要改为授予更宽泛的权限。

## 6. 创建节点池与可选的 PIS 验证

### 6.1 日常新建池：不使用 PIS（推荐）

若节点池每天重建，且不依赖预缓存镜像或 build-time OS customization，按普通 AKS 流程创建，不传 `--prepared-image-specification-id`：

```bash
export CLUSTER_NAME="<aks-cluster>"
export NODE_POOL="<node-pool-name>"
export NODE_VM_SIZE="<supported-vm-sku>"

az aks nodepool add \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster-name "${CLUSTER_NAME}" \
  --name "${NODE_POOL}" \
  --os-type Linux \
  --os-sku Ubuntu \
  --node-vm-size "${NODE_VM_SIZE}" \
  --node-count 1 \
  --ssh-access disabled
```

同一 canary 集群中的非 PIS 对照池从 AKS operation 开始到 `Succeeded` 用时 1 分 19 秒，节点为 Ubuntu 24.04.5 / Kubernetes 1.35.7 并进入 `Ready`。本审阅包仅用于审查文件，不需要为了存放它而让每日新建池承担 PIS 镜像准备成本。

### 6.2 可选：隔离测试 PIS

只有在评估预缓存镜像或 OS customization 对后续重复 scale-out 的收益时，才执行本节。创建全新 node pool 会把 PIS 镜像准备成本计入 create/update 时间。

创建隔离测试节点池：

使用当前 AKS CLI 支持的 VM SKU、网络配置及节点池参数。以下 `<supported-vm-sku>` 是占位符，执行前必须替换：

```bash
export CLUSTER_NAME="<aks-cluster>"
export NODE_POOL="pisreview"
export NODE_VM_SIZE="<supported-vm-sku>"

az aks nodepool add \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster-name "${CLUSTER_NAME}" \
  --name "${NODE_POOL}" \
  --os-type Linux \
  --os-sku Ubuntu \
  --node-vm-size "${NODE_VM_SIZE}" \
  --node-count 1 \
  --node-taints purpose=pis-review:NoSchedule \
  --labels purpose=pis-review \
  --ssh-access disabled \
  --prepared-image-specification-id "${PIS_VERSION_ID}"
```

`NoSchedule` 污点防止普通工作负载调度到 canary 节点；仅在专用验证期间使用。`--ssh-access disabled` 避免为临时测试池启用 SSH。

查看节点池和关联版本：

```bash
az aks nodepool show \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster-name "${CLUSTER_NAME}" \
  --name "${NODE_POOL}" \
  --query '{
    provisioningState:provisioningState,
    powerState:powerState.code,
    preparedImageSpecificationId:preparedImageSpecificationProfile.preparedImageSpecificationId,
    osType:osType,
    osSku:osSku
  }' \
  --output yaml
```

等待 `provisioningState` 为 `Succeeded`。失败时停止推广，先检查 AKS Activity Log、node pool 操作错误和 PIS 文档给出的故障排查项；不要通过运行包内脚本“补齐”构建状态。

如果 node pool 长时间处于 `Creating`，查看 AKS 当前操作：

```bash
az aks operation show-latest \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --nodepool-name "${NODE_POOL}" \
  --output jsonc
```

`CreatingAgentPool: 0/1 nodes completed` 表示初始节点尚未完成创建；持续观察 `status`、`error`、node pool Activity Log 和 node resource group 中对应 VMSS/实例状态。PIS 临时 build VMSS 在 customization/generalize 后显示 `VM deallocated` 本身并不表示目标 node pool 失败；本示例观察到 `pis-script-0` 和 `pis-linux-generalize` Run Command 完成、build VMSS deallocate 后，node pool 操作仍短暂处于创建中，之后转为 `Succeeded`。如果 operation 显示失败或长时间无进展，不要反复提交创建请求；保留 operation ID、Activity Log correlation ID 和错误信息，并按 [PIS 官方故障排查说明](https://learn.microsoft.com/en-us/azure/aks/prepared-image-specification-overview)或 Azure 支持渠道处理。

### 6.3 检查镜像中的文件（仅限 PIS 测试）

获取节点名称：

```bash
az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --overwrite-existing

export NODE_NAME="$(
  kubectl get nodes \
    -l "agentpool=${NODE_POOL}" \
    -o jsonpath='{.items[0].metadata.name}'
)"
test -n "${NODE_NAME}"
```

启动节点调试容器并进入 host 文件系统：

```bash
kubectl debug \
  "node/${NODE_NAME}" \
  -it \
  --image=mcr.microsoft.com/azurelinux/busybox:1.36

chroot /host /bin/bash
```

在 host shell 中只做只读验证：

```bash
cd /opt/azure-init-review
cat BUNDLE-MANIFEST.txt
sha256sum --check SHA256SUMS

find . -type f -name '*.sh' -exec stat -c '%a %n' {} \;

while IFS= read -r script; do
  bash -n "${script}" || exit 1
done < <(find . -type f -name '*.sh' -print)
```

预期：校验和全部为 `OK`；脚本文件权限为 `644`；`bash -n` 无语法错误。上述操作只是检查文件，**不要**执行 `bash <script>`、`source <script>` 或运行 `k8s_init.azure.redacted.sh`。

退出 debug shell 和 chroot 后，按集群策略找到并删除本次 debug pod：

```bash
exit
exit
kubectl get pods --all-namespaces | grep node-debugger
kubectl delete pod -n "<debug-pod-namespace>" "<debug-pod-name>"
```

## 7. 版本升级、推广与回滚

### 7.1 AKS 1.36.1 / PIS canary 实测

以下为隔离 AKS canary 集群的验证结果。PIS 测试池使用 Ubuntu、1 个节点和 `purpose=pis-validation:NoSchedule` 污点；业务节点池没有随本次 canary 节点池升级。

| 操作 | AKS operation 时间（UTC） | 用时 | 结果 |
| --- | --- | ---: | --- |
| PIS canary pool 扩容：1 → 2 节点 | — | 1 分 43 秒 | `Succeeded`；两个节点 Ready，PIS bundle 均通过 checksum 与 `bash -n` |
| PIS canary pool 缩容：2 → 1 节点 | — | 52 秒 | `Succeeded`；保留节点 Ready |
| canary pool 将 PIS profile 从 `v1` 更新到测试版 `v2` | — | 29 分 34 秒 | `Succeeded` |
| 仅升级 control plane：Kubernetes `1.35.7` → `1.36.1` | — | 9 分 59 秒 | `Succeeded` |
| 升级 PIS canary pool：Kubernetes `1.35.7` → `1.36.1` | — | 24 分 04 秒 | `Succeeded` |

PIS 版本 `v2` 是仅供此次验证的版本：保留 `v1` 的静态审阅包复制脚本，并额外写入 `/etc/aks-pis-validation/pis-version` 标记；它不执行审阅包内脚本，也不应直接推广为生产配置。

control plane 操作明确使用了 `--control-plane-only`，完成后业务节点池和 PIS canary pool 仍报告 `1.35.7`。这说明只升级 control plane 不等于同步升级节点池。随后对 PIS canary pool 单独执行 `az aks nodepool upgrade --kubernetes-version 1.36.1`。升级期间，AKS 为引用的 PIS 版本重新执行镜像准备流程：

- PIS builder VMSS 被创建；customization Run Command 和 Linux generalize 均成功，单项执行为十几至二十余秒。
- builder VMSS deallocate 后约 13 分钟，surge 节点出现并加入 `v1.36.1` 的 `Ready` 节点；AKS operation 最终 `Succeeded`，总耗时约 24 分钟。
- 验证后的节点仍引用 `pis-review-copy-only/versions/v2`。在最终节点上确认 PIS 版本标记、`SHA256SUMS` 全部校验通过，bundle 内 shell 文件均通过 `bash -n`。

中文 Microsoft Learn 文档说明：Kubernetes 版本升级时，AKS 会为节点池所引用的 PIS 版本自动重新生成 prepared VHD；无需仅为 Kubernetes 版本变化创建新的 PIS version。PIS 内容变化（脚本或容器镜像）才需要新建 PIS version。该自动准备发生在节点池升级流程中；**control-plane-only 升级不会替代节点池升级**。

#### 观察到的影响与边界

- canary pool 配置了 `maxSurge: 10%`。单节点池升级期间，VMSS capacity 临时从 1 增至 2；新节点 Ready 后旧节点进入 `SchedulingDisabled`，之后移除 surge 节点。验证池有 NoSchedule 污点，没有业务工作负载调度到该池。
- surge 节点刚加入时，部分 `kube-system` Pod 短暂处于 `Init` / `ContainerCreating`。升级完成后的检查中，所有活动节点均为 `Ready`，没有 `Pending` 或 `Failed` Pod；canary pool 回到 1 个节点。
- control plane 升级前后抽查时，活动节点均为 `Ready`，未观察到 `Pending` 或 `Failed` Pod。此次没有持续探测 API 可用性，也没有对业务工作负载执行请求/事务测试，因此这些检查不能证明整个升级窗口内零中断。
- 验证结束时，control plane 和 PIS canary pool 为 `1.36.1`；业务节点池仍为 `1.35.7`。业务节点池保留在 `1.35.7` 是本次限定只验证 canary 的结果，不代表它们已升级。
- 这次 PIS Kubernetes 升级仍花了约 24 分钟，说明即使 customization 很短，PIS 镜像准备和后续滚动节点替换仍会占据升级时间；公开 Activity Log 没有暴露 prepared VHD 服务端各子阶段的详细耗时。

### 7.2 通用前置检查与变更记录

下面的命令以 Bash、Azure CLI、`kubectl` 和已经登录的正确 subscription 为前提。开始前复核订阅、cluster、resource group、目标 pool、维护窗口和变更审批；不要把示例变量原样用于生产。若 PIS 和 AKS cluster 位于同一个 resource group，`PIS_RESOURCE_GROUP` 与 `RESOURCE_GROUP` 设置为相同值。后续涉及工作区文件的命令从仓库根目录运行。

```bash
export RESOURCE_GROUP="<aks-resource-group>"
export CLUSTER_NAME="<aks-cluster-name>"
export NODE_POOL="<target-nodepool>"
export PIS_RESOURCE_GROUP="<pis-resource-group>"
export PIS_NAME="<prepared-image-specification-name>"

az account show --query '{subscription:id,name:name}' -o yaml
az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" \
  --query '{location:location,state:provisioningState,kubernetesVersion:kubernetesVersion}' -o yaml
az aks nodepool show -g "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" \
  -n "${NODE_POOL}" \
  --query '{state:provisioningState,count:count,autoscaling:enableAutoScaling,min:minCount,max:maxCount,kubernetesVersion:currentOrchestratorVersion,nodeImageVersion:nodeImageVersion,pisId:preparedImageSpecificationProfile.preparedImageSpecificationId,taints:nodeTaints}' \
  -o yaml

az aks get-credentials -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --overwrite-existing
kubectl get nodes -o wide
kubectl get pods -A --field-selector=status.phase=Pending -o wide
kubectl get pods -A --field-selector=status.phase=Failed -o wide
```

如果 cluster 或 pool 不是 `Succeeded`、现有节点不是健康状态、存在未处理的 Pending/Failed workload，先查明原因并暂停变更。操作期间记录 UTC 开始/结束时间、operation ID、状态、节点数量/Ready 状态、PIS version、Kubernetes 版本和业务健康探测结果。`kubectl get nodes` 和 Pod phase 只是抽样；生产变更还需使用应用自己的 readiness、请求/事务探测和告警。

### 7.3 扩容与缩容 PIS node pool

手动调整固定节点数时，先检查 quota、子网 IP、VM SKU 容量、PDB 和可用容量。启用 cluster autoscaler 的池应按批准的 `minCount` / `maxCount` 调整，不要用手动 scale 与 autoscaler 相互覆盖。缩容会驱逐并终止节点上的 Pod；先确认 workload 有足够副本、PDB 可满足且目标节点无不可丢失的本地状态。AKS 会执行节点池缩容流程，不要用删除 VMSS 实例代替。

```bash
export TARGET_COUNT=2
printf 'scale-out submit UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
az aks nodepool scale \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster-name "${CLUSTER_NAME}" \
  --name "${NODE_POOL}" \
  --node-count "${TARGET_COUNT}"
printf 'scale-out returned UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
```

等待预期数量的节点加入且全部 `Ready`；同时确认 pool operation 已成功：

```bash
az aks operation show-latest -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" \
  --nodepool-name "${NODE_POOL}" -o jsonc
az aks nodepool show -g "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" \
  -n "${NODE_POOL}" --query '{state:provisioningState,count:count}' -o yaml
kubectl get nodes -l "agentpool=${NODE_POOL}" -o wide
kubectl wait --for=condition=Ready nodes \
  -l "agentpool=${NODE_POOL}" --timeout=15m
```

验证**每个**新增节点的 PIS 内容，而不是只抽查一个节点。参照 §6.3 获取该 pool 的 node names，在各节点上用 `kubectl debug node/<node> --profile=sysadmin` 只读检查 `/opt/azure-init-review/SHA256SUMS` 与 shell 语法；不要执行包内脚本。检查完成后删除 debug Pod。

缩容到目标数量前，先确认目标数量及 autoscaler 设置符合审批；随后用相同方式执行：

```bash
export TARGET_COUNT=1
printf 'scale-in submit UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
az aks nodepool scale \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster-name "${CLUSTER_NAME}" \
  --name "${NODE_POOL}" \
  --node-count "${TARGET_COUNT}"
printf 'scale-in returned UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
```

缩容后确认 pool count、剩余节点 Ready、Pod 分布及应用健康。若 operation 失败或长期无进展，停止重复提交并保留 operation/Activity Log 证据。

### 7.4 更新 PIS customization / prepared image version

PIS 版本内容不可原地覆盖。脚本、容器镜像或其他 PIS 输入发生变化时，创建**新的唯一版本**，先在隔离 canary pool 更新和验证，再按审批推广。单纯 Kubernetes 版本升级不需要另建 PIS version：AKS 会为被引用的 PIS 自动重建 prepared VHD。

```bash
export NEW_PIS_VERSION="review-bundle-v3"
export LOCATION="$(
  az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --query location -o tsv
)"
export PIS_JSON="azure-init-review/pis-scripts.json"

# 先确认新版本名称尚未使用、JSON 内容符合预期且不含 secret。
az aks prepared-image-specification version list \
  --resource-group "${PIS_RESOURCE_GROUP}" --pis-name "${PIS_NAME}" -o table
jq '.[].name' "${PIS_JSON}"

az aks prepared-image-specification create \
  --resource-group "${PIS_RESOURCE_GROUP}" \
  --name "${PIS_NAME}" \
  --version "${NEW_PIS_VERSION}" \
  --location "${LOCATION}" \
  --customization-scripts "@${PIS_JSON}"

export NEW_PIS_VERSION_ID="$(
  az aks prepared-image-specification version show \
    --resource-group "${PIS_RESOURCE_GROUP}" \
    --pis-name "${PIS_NAME}" \
    --name "${NEW_PIS_VERSION}" \
    --query id -o tsv
)"
test -n "${NEW_PIS_VERSION_ID}"
printf 'candidate PIS version: %s\n' "${NEW_PIS_VERSION_ID}"
```

PIS version resource 创建成功**不表示 prepared VHD 已准备好**。把新 version 先关联到 canary pool；此更新可能重新执行 PIS customization、generalize、准备镜像并替换节点，须按长时操作监控：

```bash
export OLD_PIS_VERSION_ID="$(
  az aks nodepool show -g "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" \
    -n "${NODE_POOL}" \
    --query preparedImageSpecificationProfile.preparedImageSpecificationId -o tsv
)"
test -n "${OLD_PIS_VERSION_ID}"
printf 'old PIS: %s\nnew PIS: %s\n' "${OLD_PIS_VERSION_ID}" "${NEW_PIS_VERSION_ID}"
printf 'PIS version rollout submit UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'

az aks nodepool update \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster-name "${CLUSTER_NAME}" \
  --name "${NODE_POOL}" \
  --prepared-image-specification-id "${NEW_PIS_VERSION_ID}"

printf 'PIS version rollout returned UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
az aks operation show-latest -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" \
  --nodepool-name "${NODE_POOL}" -o jsonc
```

只有当 operation 为 `Succeeded`、pool 的 `preparedImageSpecificationProfile.preparedImageSpecificationId` 等于候选 ID、节点 Ready 且 PIS 内容验证通过后，才允许推广到其他 pool。记录 operation 和 PIS builder/VMSS Activity Log 的 correlation ID；builder deallocate 并不代表 pool operation 已完成。

**区分 PIS 内容更新与 AKS node OS image 更新：** 修改 PIS script/image 内容时创建新的 PIS version 并更新 pool profile，如上所述。AKS 基础 Ubuntu/node image 有更新时，使用以下检查和 node image-only 操作；这不会更改 PIS version ID，也不能代替 PIS 内容版本变更。对关联 PIS 的 pool，实际升级期间需同样跟踪 PIS/VMSS Activity Log，并在节点 Ready 后重新验证 PIS profile 和文件。

```bash
az aks nodepool get-upgrades \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster-name "${CLUSTER_NAME}" \
  --nodepool-name "${NODE_POOL}" \
  --query '{current:kubernetesVersion,latestNodeImageVersion:latestNodeImageVersion,upgrades:upgrades}' \
  -o yaml

printf 'node image-only upgrade submit UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
az aks nodepool upgrade \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster-name "${CLUSTER_NAME}" \
  --name "${NODE_POOL}" \
  --node-image-only \
  --yes
printf 'node image-only upgrade returned UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
az aks operation show-latest -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" \
  --nodepool-name "${NODE_POOL}" -o jsonc
```

仅当 upgrade profile 显示存在较新的 `latestNodeImageVersion` 时执行；若它与当前 pool 的 `nodeImageVersion` 一致或升级 profile 没有可用更新，不要为了验证而重复触发。Azure CLI 当前提供 `az aks nodepool upgrade --node-image-only`，操作前再次用 `az aks nodepool upgrade -h` 确认本地 CLI/aks-preview 版本支持该参数。

### 7.5 升级 AKS Kubernetes 版本（control plane 和节点池）

先确认目标版本属于 AKS 返回的可升级版本，目标 node pool 的升级 profile 也允许该版本；Kubernetes 版本升级应按 control plane 后 node pool 的顺序执行，node pool 版本不得高于 control plane。检查 workload API deprecation/兼容性、PDB、容量、配额和 subnet IP，准备维护窗口及回滚/恢复方案。

```bash
export TARGET_K8S_VERSION="<version-listed-by-aks>"

az aks get-upgrades -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" -o table
az aks nodepool list -g "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" \
  --query '[].{name:name,state:provisioningState,count:count,version:currentOrchestratorVersion,pis:preparedImageSpecificationProfile.preparedImageSpecificationId}' \
  -o table
az aks nodepool get-upgrades -g "${RESOURCE_GROUP}" \
  --cluster-name "${CLUSTER_NAME}" --nodepool-name "${NODE_POOL}" -o jsonc
```

对需要分批/先 canary 验证的变更，先只升级 control plane：

```bash
printf 'control plane upgrade submit UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
az aks upgrade \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --kubernetes-version "${TARGET_K8S_VERSION}" \
  --control-plane-only \
  --yes
printf 'control plane upgrade returned UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" \
  --query '{state:provisioningState,version:kubernetesVersion}' -o yaml
```

control plane 成功后，**这一步不会同步升级任何 node pool**。先升级 PIS canary pool，并按 §7.4 的长时操作监控、检查 PIS profile 与节点/工作负载；然后对每个获批 pool 逐一执行：

```bash
printf 'node pool upgrade submit UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
az aks nodepool upgrade \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster-name "${CLUSTER_NAME}" \
  --name "${NODE_POOL}" \
  --kubernetes-version "${TARGET_K8S_VERSION}" \
  --yes
printf 'node pool upgrade returned UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
az aks operation show-latest -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" \
  --nodepool-name "${NODE_POOL}" -o jsonc
```

引用 PIS 的 pool 在 Kubernetes 升级时，AKS 会自动为已引用的 PIS version 重新生成 prepared VHD；无需仅因 Kubernetes 版本变化新建 PIS version。预期耗时包含镜像准备与节点滚动替换，应预留时间。逐个 pool 等到 operation `Succeeded`、目标版本正确、节点 Ready、应用探测通过后，再推进下一个 pool。

如果变更审批明确允许一次性升级**整个 cluster 的所有 node pools**，可以在确认 `az aks get-upgrades` 返回目标版本并评估所有 pool 的维护影响后，使用：

```bash
az aks upgrade \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --kubernetes-version "${TARGET_K8S_VERSION}" \
  --yes
```

该命令未指定 `--control-plane-only` 时，会升级 control plane **和所有 node pools**，包括引用 PIS 的池；不应将其用于只想验证某个 canary pool 的变更。升级中记录 cluster operation、各 pool 状态及 PIS builder 事件。不要同时对同一 cluster 发起第二个升级/更新操作。

### 7.6 回滚与验收

- **PIS version 回滚：** 先保存上一版 PIS ID，再把目标 node pool 的 profile 更新回该 ID：

  ```bash
  az aks nodepool update \
    --resource-group "${RESOURCE_GROUP}" \
    --cluster-name "${CLUSTER_NAME}" \
    --name "${NODE_POOL}" \
    --prepared-image-specification-id "${OLD_PIS_VERSION_ID}"
  ```

  这仍然是 node pool update，可能再次准备镜像并滚动替换节点，不是瞬时切换。等待 operation 成功后复验版本 ID、节点 Ready、PIS bundle 和 workload。

- **Kubernetes 版本回滚：** AKS 通常不支持将 Kubernetes 版本降级。不要把回滚 PIS ID 或重建 pool 当作 Kubernetes 降级方案；发生升级故障时先停止继续 rollout，收集 operation/error/Activity Log 并按 AKS 支持流程处理。优先使用 AKS 支持的前向修复版本。
- **验收：** cluster/pool provisioning state 为 `Succeeded`；control plane 与目标 pool 的版本符合计划；PIS profile 指向预期版本；目标 pool 节点数量正确且全部 `Ready`；没有未解释的 Pending/Failed Pod；PIS 文件 checksum/语法验证通过；应用自身健康检查、关键请求/事务和监控恢复正常。
- **清理测试池：** 确认池中无工作负载且变更审批允许后，删除专用测试池；不要对生产池执行删除操作。清理 canary 前，需确认用户不再需要保留该池。

若要把这些脚本从“文件”升级成真正的节点初始化行为，应另行设计受支持的节点生命周期机制，逐项处理下表中的环境依赖、幂等、失败恢复、权限、网络来源、密钥管理和磁盘安全，并在非生产环境测试。不要直接把完整主脚本改成 `NodeImageBuildTime` customization。

## 8. 相关文档

- [PIS 概述：Prepared Image Specification (PIS) in Azure Kubernetes Service (AKS) (Preview)](https://learn.microsoft.com/en-us/azure/aks/prepared-image-specification-overview)
- [创建和管理 AKS Prepared Image Specification (PIS) (Preview)](https://learn.microsoft.com/en-us/azure/aks/prepared-image-specification)
- [AKS Support Policies / agent node shared responsibility](https://learn.microsoft.com/en-us/azure/aks/support-policies#shared-responsibility)
- [Customize the Node Configuration for AKS Node Pools](https://learn.microsoft.com/en-us/azure/aks/custom-node-configuration)
- [DNS in AKS](https://learn.microsoft.com/en-us/azure/aks/dns-concepts)
- [Azure IP 168.63.129.16 Overview](https://learn.microsoft.com/en-us/azure/virtual-network/what-is-ip-address-168-63-129-16)
- [Time sync for Linux VMs in Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/time-sync)
- [PIS 脚本审阅包说明](../azure-init-review/README.md)
- [PIS Bash 打包 JSON](../azure-init-review/pis-scripts.json)
- [PIS JSON 生成器](../tools/build_azure_init_pis.py)
