#!/bin/bash
# Azure-only, redacted review copy. Original execution order is preserved.
# Internal endpoints and credentials are placeholders; this copy is for review.
log_file="/var/log/k8s_node_init.log"
echo > $log_file

function echoE(){
start_current_date="`date "+%Y-%m-%d %H:%M:%S"`"
echo  ${start_current_date}  $1  >> $log_file
}

cloud_name=$1

#dns_server_list_str=$2
dns_server_workspace_code=$2

# echoE "传入参数: 云 $cloud_name  dns server workspace code:$dns_server_workspace_code"
is_i8n=$3
echoE "传入参数: 云 $cloud_name  dns server workspace code:$dns_server_workspace_code   是否是海外:$is_i8n"

# Azure-specific configuration.
# Only Azure-managed data disks exposed as LUN 0 and LUN 1 are eligible.
# The OS disk and Azure resource/temporary disk are explicitly rejected.
function set_kernel_param_azure() {
    if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' /etc/sysctl.conf; then
        sed -ri 's|^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*|net.ipv4.ip_forward = 1|' /etc/sysctl.conf
    else
        echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    fi
    sysctl -w net.ipv4.ip_forward=1
}

function azure_data_disk_by_lun() {
    local lun="$1"
    local disk_path

    for disk_path in "/dev/disk/azure/data/by-lun/${lun}" "/dev/disk/azure/scsi1/lun${lun}"
    do
        if [ -b "${disk_path}" ]; then
            readlink -f "${disk_path}"
            return 0
        fi
    done
    return 1
}

function azure_validate_disk() {
    local disk
    local root_source
    local root_parent
    local resource_disk
    disk="$(readlink -f "$1")"
    root_source="$(readlink -f "$(findmnt -nro SOURCE /)")"
    root_parent="$(lsblk -nro PKNAME "${root_source}" 2>/dev/null | head -1)"
    [ -n "${root_parent}" ] && root_parent="/dev/${root_parent}"
    resource_disk="$(readlink -f /dev/disk/azure/resource 2>/dev/null)"

    if [ ! -b "${disk}" ]; then
        echoE "azure disk ${disk} is not a block device"
        return 1
    fi
    if [ "${disk}" = "${root_source}" ] || [ "${disk}" = "${root_parent}" ]; then
        echoE "azure refuses OS disk ${disk}"
        return 1
    fi
    if [ -n "${resource_disk}" ] && [ "${disk}" = "${resource_disk}" ]; then
        echoE "azure refuses resource temporary disk ${disk}"
        return 1
    fi
    if [ "$(lsblk -nrpo NAME "${disk}" | wc -l)" -ne 1 ]; then
        echoE "azure disk ${disk} has partitions or child devices"
        return 1
    fi
}

function azure_mount_disk() {
    local disk
    local mount_point="$2"
    local fs_type
    local disk_uuid
    local fstab_source
    local mounted_source
    disk="$(readlink -f "$1")"

    azure_validate_disk "${disk}" || return 1

    fs_type="$(blkid -s TYPE -o value "${disk}" 2>/dev/null)"
    if [ -n "${fs_type}" ] && [ "${fs_type}" != "xfs" ]; then
        echoE "azure disk ${disk} has unsupported filesystem ${fs_type}"
        return 1
    fi

    if [ -z "${fs_type}" ]; then
        if wipefs -n "${disk}" 2>/dev/null | grep -q .; then
            echoE "azure disk ${disk} contains an unknown signature"
            return 1
        fi
        echoE "azure formats new disk ${disk} as xfs"
        /usr/sbin/mkfs.xfs "${disk}" || return 1
    fi

    disk_uuid="$(blkid -s UUID -o value "${disk}" 2>/dev/null)"
    if [ -z "${disk_uuid}" ]; then
        echoE "azure disk ${disk} uuid is null"
        return 1
    fi

    if [ -d "${mount_point}" ] && mountpoint -q "${mount_point}"; then
        mounted_source="$(readlink -f "$(findmnt -nro SOURCE "${mount_point}")")"
        if [ "${mounted_source}" != "${disk}" ]; then
            echoE "azure mount point ${mount_point} is already used by ${mounted_source}"
            return 1
        fi
        echoE "azure disk ${disk} is already mounted on ${mount_point}"
        return 0
    fi

    fstab_source="$(awk -v mp="${mount_point}" '$1 !~ /^#/ && $2 == mp {print $1; exit}' /etc/fstab)"
    if [ -n "${fstab_source}" ] && [ "${fstab_source}" != "UUID=${disk_uuid}" ]; then
        echoE "azure mount point ${mount_point} has conflicting fstab source ${fstab_source}"
        return 1
    fi

    mkdir -p "${mount_point}"
    if [ -z "${fstab_source}" ]; then
        echo "UUID=${disk_uuid} ${mount_point} xfs defaults,noatime,nofail,x-systemd.device-timeout=30s 0 2" >> /etc/fstab
    fi
    mount "${mount_point}" || return 1
    echoE "azure mounted ${disk} on ${mount_point}"
}

function disk_init_azure() {
    local lun0_disk
    local lun1_disk
    local cce_disk
    local data_disk
    local lun0_size
    local lun1_size
    local required_cmd

    for required_cmd in findmnt lsblk blockdev blkid wipefs mountpoint mount awk readlink /usr/sbin/mkfs.xfs
    do
        command -v "${required_cmd}" >/dev/null 2>&1 || {
            echoE "azure required command is missing: ${required_cmd}"
            return 1
        }
    done

    lun0_disk="$(azure_data_disk_by_lun 0)" || {
        echoE "azure managed data disk LUN 0 was not found"
        return 1
    }
    lun1_disk="$(azure_data_disk_by_lun 1)" || {
        echoE "azure managed data disk LUN 1 was not found"
        return 1
    }

    if [ "${lun0_disk}" = "${lun1_disk}" ]; then
        echoE "azure LUN 0 and LUN 1 resolve to the same disk"
        return 1
    fi

    lun0_size="$(blockdev --getsize64 "${lun0_disk}")" || return 1
    lun1_size="$(blockdev --getsize64 "${lun1_disk}")" || return 1
    if [ "${lun0_size}" -le "${lun1_size}" ]; then
        cce_disk="${lun0_disk}"
        data_disk="${lun1_disk}"
    else
        cce_disk="${lun1_disk}"
        data_disk="${lun0_disk}"
    fi

    echoE "azure selected ${cce_disk} for /cce and ${data_disk} for /data"
    azure_mount_disk "${cce_disk}" /cce || return 1
    azure_mount_disk "${data_disk}" /data || return 1
}

function azure_set() {
    echoE "azure specific configuration started"
    set_kernel_param_azure || return 1
    disk_init_azure || return 1
    echoE "azure specific configuration completed"
}


################### 公共部分 ##################
# env
function env_init() {
    echoE "python软连接设置"
    [ -f /usr/bin/python3 ] && ln -s  /usr/bin/python3 /usr/bin/python 

    echoE "开始关闭防火墙"
    systemctl stop firewalld
    systemctl disable firewalld &> /dev/null

    echoE "开始关闭SELINUX"
    sed -ri 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    rm -f /etc/localtime && ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
}


function dns_init() {
    dns_addr=$1
    dns_addr_list=`echo ${dns_addr} | sed 's/,/ /g'`
    echo "options timeout:1 attempts:2" > /etc/resolv.conf
    for denv in ${dns_addr_list}
    do
        echo "nameserver ${denv}" >> /etc/resolv.conf
    done

    /usr/bin/sed -i '/init_fluash*/d' /etc/cron.d/watchdog
    /usr/bin/sed -i '/dns_flush*/d' /etc/cron.d/watchdog
    /usr/bin/rm -f /company/devops/init_fluash.sh
    /usr/bin/rm -f /opt/devops/dns_flush.sh
    sleep 5
    /usr/bin/chattr +i /etc/resolv.conf
}

function node_user() {
  echoE "开始用户的初始化设置"
  curl http://endpoint-01.example.invalid/initialization/scripts/init_user.sh |bash
  echoE "用户的初始化设置完成"
}

function log_clean(){
  CrontFile="/var/spool/cron/root"
  mkdir -p /company/devops/
  wget  -O /company/devops/del_log.sh http://endpoint-01.example.invalid/scripts/del_log.sh
  chmod +x /company/devops/del_log.sh

  grep del_log.sh $CrontFile &>/dev/null
  if [ $? -ne   0   ]
  then
        echo '10 */4 * *  *  /bin/bash /company/devops/del_log.sh >/dev/null 2>&1' >> $CrontFile
        echoE "日志清理策略添加完成"
  else
      echoE "日志清理策略已添加"
  fi
}

function service_init() {
  # 配置dns
  #echoE "配置dns ，传入的DNS 列表：${dns_server_list_str}"
  dns_init "192.0.2.1"
  wget  -O /tmp/dns_update_workspace.sh  http://endpoint-01.example.invalid/initialization/scripts/dns_update_workspace.sh 
  bash /tmp/dns_update_workspace.sh   $dns_server_workspace_code
  echoE "配置dns完成"

  # 设置ntp
#   echoE "进行ntp的初始化"
#   curl  http://endpoint-01.example.invalid/initialization/scripts/ntpdate_set.sh |bash

  echoE "进行ntp的初始化"
  if [ "${is_i8n}" == "true" ]; then
    echoE "国外环境，初始化国外NTP"
    curl http://endpoint-01.example.invalid/initialization/scripts/ntpdate_eu_set.sh |bash
  else
    echoE "国内环境，初始化国内NTP（参数为空或false）"
    curl http://endpoint-01.example.invalid/initialization/scripts/ntpdate_set.sh |bash
  fi


  # 用户初始化
  node_user

  # 日志的清理
  log_clean

  # 关闭node_exporter服务
    echoE "开始关闭node_exporter服务"
    /usr/bin/systemctl stop node_exporter
    /usr/bin/systemctl disable node_exporter
    if [ "$?" == 0 ] ; then
        echoE "node_exporter服务关闭成功"
    else
        echoE "node_exporter服务关闭失败"
    fi
}

function main() {
    env_init
    service_init
    case $cloud_name in
        "azure"|"azurecloud"|"AzureCloud")
            azure_set ;;
    esac
}
main

