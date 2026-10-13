# Azure 节点初始化脚本：脱敏审阅包

本包使用脱敏后的主机名、地址、凭据和用户名，供技术审阅脚本结构与行为。示例值不是部署配置；本包未运行任何初始化或子脚本。

本包从授权文件源只读提取，原始服务器文件未修改。

## 保留范围

- `k8s_init.azure.redacted.sh`：原主脚本的参数处理、日志函数、Azure 分支、公共初始化及入口。只删除其他云分支与其专属函数。
- `initialization/scripts/init_user.sh`：用户创建、SSH 公钥下载位置、sudo 组设置；真实账户名已替换，实际公钥文件不包含在包中。
- `initialization/scripts/dns_update_workspace.sh`：DNS 查询、更新、文件锁、CMDB API 调用和内嵌 Python 全部保留，认证头已脱敏。
- `initialization/scripts/ntpdate_set.sh`、`ntpdate_eu_set.sh`：国内和海外 NTP 路径均保留，因为第三个参数的实际取值未确认。
- `scripts/del_log.sh`：日志、dump、journal 清理及 cron 检查逻辑。

子脚本保留原文件名及相对目录，与主脚本中脱敏 URL 的路径对应。没有把下载执行改成另一种执行方式，也没有把子脚本合并执行。

## 执行顺序及嵌套关系

```text
k8s_init.azure.redacted.sh <azure|azurecloud|AzureCloud> <workspace_code> <is_overseas>
  main
    env_init
      Python 软链接、firewalld、SELinux、时区设置
    service_init
      dns_init
      下载并运行 dns_update_workspace.sh
        内嵌 Python：创建 UDP socket 获取本机出口地址
        内嵌 Python：解析 CMDB JSON 响应
      is_overseas == true → ntpdate_eu_set.sh
      其他情况 → ntpdate_set.sh
      node_user → init_user.sh → 公钥下载引用（不含实际密钥）
      log_clean → 下载 del_log.sh 并配置 cron
        cron 后续运行 del_log.sh；其中还有自下载检查
      停止并禁用 node_exporter
    azure_set
      set_kernel_param_azure → net.ipv4.ip_forward=1
      disk_init_azure
        检查 Azure LUN 0/1、OS 盘、临时盘、分区和文件系统
        按磁盘大小选择 /cce、/data
        azure_mount_disk → 必要时格式化、写 fstab、挂载
```

Azure 分支前会执行公共部分，因此单独提交 Azure 函数会遗漏实际初始化行为。其他云专属的 sysctl/limits 配置及 containerd 迁移不属于本包的 Azure 路径。

## 脱敏规则

- 主机、文件服务器、CMDB、NTP 等地址替换为 `endpoint-NN.example.invalid`。
- IPv4 地址替换为 `192.0.2.N` 示例地址；同一地址在提取过程中保持一致映射。
- Authorization 认证值替换为 `REDACTED_AUTHORIZATION`，原凭据不包含在包中。
- 用户名已替换为一致性占位符，真实名称及映射未包含在本包中。
- 公司路径前缀替换为 `/company/`，公司 API 路径标签替换为 `cmdb-api`；参数、API 字段、系统路径、LUN、挂载点、cron 周期及判断逻辑保留。
- 不包含真实 SSH 公钥文件、替换前后映射表、其他云代码或服务器历史文件。

本包保留原脚本行为供审阅，没有修复或重新设计初始化逻辑，因此不能直接作为部署配置使用。

## 版本与验证边界

本分享版不记录源文件指纹。

所有子脚本为文件服务器当前版本，不代表问题节点初始化时实际下载的历史版本。若用于事故归因，还应比对节点初始化日志、执行参数及历史文件版本。

6 个 shell 文件均通过 `bash -n`；DNS 脚本内嵌 Python 通过语法解析。另进行了认证头、公司标识、地址和密钥特征残留检查。仅做静态验证，没有执行脚本。
