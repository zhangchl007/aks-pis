# Runbook：将 `azure-init-review` 审阅包打入 AKS PIS 镜像

## 1. 目的与安全边界

本 runbook 将 `azure-init-review` 中的主初始化脚本、子脚本、审阅说明和校验清单作为**静态文件**复制到 AKS PIS prepared image：

```text
/opt/azure-init-review/
```

PIS customization 只解码、校验和安装这些文件；**不会 source、执行或下载其中任何初始化脚本**。这一区分是强制安全边界：此审阅包不是可直接部署的初始化版本。

> **禁止直接运行包内脚本。** [README.md](../azure-init-review/README.md) 明确说明该包含脱敏占位值。当前副本使用 `.example.invalid` 主机名、`192.0.2.x` 文档示例地址和 `REDACTED_AUTHORIZATION`；这些不是生产端点或有效凭据。运行前必须由服务所有者提供已批准、完整且经过安全审查的生产版本。

### 每日重建 node pool 的实测结论

对每天删除并新建节点池的工作流，**不要把 PIS 作为默认路径**。PIS 会在关联它的 node pool create/update 流程中准备镜像；每次新建池都可能再次触发这项准备。Microsoft Learn 将其收益定位在镜像准备后的重复 scale-out，并指出初次 create/update 会因构建镜像而更慢。

在 `taugrid-phase1-itn`（`italynorth`、Kubernetes `1.35.7`）使用同一 `Standard_D4as_v6` 做了实测：

| 测试 | AKS operation 时间 | 节点结果 |
| --- | ---: | --- |
| PIS 池，第 1 次 | 18 分 20 秒 | `Succeeded`，节点 `Ready` |
| PIS 池，第 2 次 | 17 分 02 秒 | `Succeeded`，节点 `Ready` |
| PIS 池，仅 `echo` 简单脚本 | 18 分 00 秒 | `Succeeded`，节点 `Ready` |
| 普通 Ubuntu 池，不关联 PIS | 1 分 19 秒 | `Succeeded`，节点 `Ready` |

第二次 PIS 测试中，customization Run Command 从 `01:29:57Z` 到 `01:30:19Z`，约 **22 秒**；generalize Run Command 也约 **22 秒**。额外创建的简单脚本对照中，`echo PIS_NOOP_OK` 从 `02:01:09.913Z` 到 `02:01:32.685Z`，约 **22.8 秒**；generalize 从 `02:02:11.136Z` 到 `02:02:34.046Z`，约 **22.9 秒**。builder VM 于 `02:03:19.748Z` deallocate，目标 node pool VMSS 到 `02:16:35.638Z` 才开始创建，相隔 **13 分 16 秒**；整个 AKS operation 于 `02:17:49Z` 结束，节点随后 `Ready`。因此简化脚本没有显著缩短端到端耗时，脚本复杂度不是主因。

每次新建 PIS 池都会产生临时 builder VMSS；普通池对照在同集群、同 SKU 下 79 秒完成。因此本工作流的可操作根因是：**每天新建池重复进入 PIS 镜像准备路径**。本审阅包只有静态文件复制，没有容器镜像预缓存或其他能补偿该成本的用途。

Activity Log 只记录了 build VM、Run Command 和目标 VMSS 等 ARM 操作；PIS 服务端镜像准备的内部子阶段未暴露，因此不能将 deallocate 后约 12–13 分钟的等待进一步断言为某个特定快照/捕获动作。Microsoft Learn 没有给出初次 PIS 构建的分钟数或时长 SLA；它只说明初次 node pool create/update 会先构建镜像，因此会耗时更长。这个服务端子阶段是否达到产品预期，公开资料无法判定；但该未知项不影响当前修复决策：日常新建池应不使用 PIS。若业务必须使用 PIS 且需要追查内部子阶段，可向 Microsoft Support 提供 PIS 测试的 correlation ID `d25680f4-d973-4e88-99c8-f655f613c564`、简单脚本对照的 operation ID `63730ab2-2655-4d84-9d16-d27fa366d35c` / correlation ID `7ba3aa35-e943-4cf0-b67e-a5e3ceb89386`，以及本文时间线和区域/SKU。

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

本次同集群、同 `Standard_D4as_v6` 对照池从 AKS operation 开始到 `Succeeded` 用时 1 分 19 秒，节点为 Ubuntu 24.04.5 / Kubernetes 1.35.7 并进入 `Ready`。本审阅包仅用于审查文件，不需要为了存放它而让每日新建池承担 PIS 镜像准备成本。

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

## 7. 更新、推广与回滚

- **源脚本或 bundle 改变：** 重新运行生成器；先审核源变更和生成 JSON，再创建新的 PIS version。不要尝试覆盖已使用版本的内容。
- **测试通过后推广：** 依据变更审批，将 PIS version ID 关联到目标 node pool；监控 node pool 更新、节点 Ready、DNS、镜像拉取和 workload 健康状况。当前 bundle 只验证文件是否存在，不代表包内初始化逻辑已经生产化。
- **回滚：** 将 node pool 更新回上一个已验证的 PIS version ID，并监控 rollout 完成。保留前一版 ID、节点池配置和审批记录。
- **清理测试池：** 确认池中无工作负载且变更审批允许后，删除专用测试池；不要对生产池执行删除操作。

若要把这些脚本从“文件”升级成真正的节点初始化行为，应另行设计受支持的节点生命周期机制，逐项处理下表中的环境依赖、幂等、失败恢复、权限、网络来源、密钥管理和磁盘安全，并在非生产环境测试。不要直接把完整主脚本改成 `NodeImageBuildTime` customization。

## 8. 相关文档

- [PIS 概述：Prepared Image Specification (PIS) in Azure Kubernetes Service (AKS) (Preview)](https://learn.microsoft.com/en-us/azure/aks/prepared-image-specification-overview)
- [创建和管理 AKS Prepared Image Specification (PIS) (Preview)](https://learn.microsoft.com/en-us/azure/aks/prepared-image-specification)
- [PIS 脚本审阅包说明](../azure-init-review/README.md)
- [PIS Bash 打包 JSON](../azure-init-review/pis-scripts.json)
- [PIS JSON 生成器](../tools/build_azure_init_pis.py)
