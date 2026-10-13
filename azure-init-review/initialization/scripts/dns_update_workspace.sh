#!/bin/bash
log_file="/var/log/dns_update.log"
echo > $log_file


workspace_code=$1
cmdb_env=$2

cmdb_url="endpoint-06.example.invalid"
if [ "$cmdb_env" == "test" ]
then
        cmdb_url="endpoint-07.example.invalid"
else
	cmdb_env="prod"
fi


function pythonenv() {
which python
if [ $? -ne 0  ]
then
        which python3
        if [ $? -ne 0  ]
        then
                echoE "无python 环境"
                exit 1
        else
                ln -s  `which python3`   /usr/bin/python
        fi
fi
}



function echoE(){
start_current_date="`date "+%Y-%m-%d %H:%M:%S"`"
echo  ${start_current_date}  $@  >> $log_file
}


function init_conf() {
    echo 'options timeout:1 attempts:2
nameserver 192.0.2.1 '> /etc/resolv.conf
}


function getIp() {
python_script='
import socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.connect(("192.0.2.2", 80))
host_ip = sock.getsockname()[0]
print(host_ip)
'

host_ip=$(python -c "$python_script")
echoE "获取主机的ip: $host_ip"
echo $host_ip
# return $host_ip
}

function debianSet(){
        systemctl stop systemd-resolved.service &&  systemctl disable systemd-resolved.service
        rm -rf  /etc/resolv.conf
        touch  /etc/resolv.conf
        echoE "debian systemd-resolved 关闭完成 "
}

function update_vdc_conf(){
        ping ${cmdb_url} -c 1
        if [ $? != 0 ]; then
                echoE "机器到cmdb ${cmdb_url} 不通"
                return  1
        fi

        if [ $workspace_code  ]
        then
                echoE "传入workspace 的code 值为:${workspace_code}, cmdb 环境:${cmdb_env}  cmdb_url:${cmdb_url}"
                url_cmdb_workspace="https://endpoint-02.example.invalid/cmdb-api/v1-0/commondata/md_workspace?sort_field=&sort_flag&code=${workspace_code}"
                vdccode=`/usr/bin/curl  -H "Authorization: REDACTED_AUTHORIZATION"  -s ${url_cmdb_workspace}   | /usr/bin/python -c "import sys, json; print(json.load(sys.stdin).get('data')[0].get('vdc'))"`
                echoE "workspace 的vdccode 值为:${vdccode}"

                if [ $vdccode ]
                then
                        url_cmdb_workspace_vdc="https://endpoint-02.example.invalid/cmdb-api/v1-0/commondata/md_vdc?sort_field=&sort_flag=&page=1&size=15&code=${vdccode}"
                        dns_strings=`/usr/bin/curl  -H "Authorization: REDACTED_AUTHORIZATION"  -s ${url_cmdb_workspace_vdc}  | /usr/bin/python -c "import sys, json; print(json.load(sys.stdin).get('data')[0].get('dns'))"`
                        echoE "workspace 的vdccode:${vdccode}  DNS列表: ${dns_strings}"


                        # url_cmdb_cell="https://endpoint-02.example.invalid/cmdb-api/v1-0/cell/all?code=${codename}"
                        # dns_strings=`/usr/bin/curl  -H "Authorization: REDACTED_AUTHORIZATION"  -s ${url_cmdb_cell}    | /usr/bin/python -c "import sys, json; print(json.load(sys.stdin)[0].get('dns')) "`
                        dns_env_arr=`echo ${dns_strings} | sed 's/,/ /g'`
                        if [ "$dns_env_arr" == "None" ]
                        then
                                echoE "DNS 列表获取失败，为：${dns_env_arr}"
                                return 1
                        fi

                        # echoE "单元名称:${codename}  dns 列表:${dns_env_arr}"
                        echo "options timeout:1 attempts:2" > /etc/resolv.conf

                        for denv in ${dns_env_arr}
                        do
                                echo "nameserver ${denv}" >> /etc/resolv.conf
                        done
                        echoE "写入DNS列表：${dns_env_arr}"
                else
                        echoE "未成功获取到workspace 的vdccode:${workspace_code}"
                        return 1
                fi
        else
                echoE "未成功获取到workspace 的code:${vdccode}"
                return 1
        fi
}


function update_conf(){

        node_ip=$(getIp)
        echoE "获取机器ip:${node_ip}"
        ping ${cmdb_url} -c 1
        if [ $? != 0 ]; then
                echoE "机器到cmdb ${cmdb_url} 不通"
                return  1
        fi

        url_cmdb_node="https://endpoint-02.example.invalid/cmdb-api/v1-0/commondata/all/md_cloud_virtual_machine?private_ip=${node_ip}&if_fuzzy_search=false"
        echoE "获取机器cmdb url:${url_cmdb_node}"

        count=0
        sign=0
        while [ $count -le 40 ]
        do
                result=`/usr/bin/curl  -H "Authorization: REDACTED_AUTHORIZATION" -s  $url_cmdb_node  | /usr/bin/python -c "import sys, json; print(len(json.load(sys.stdin)))"`
                if [  $result -ne 1 ]
                then
                        echoE "机器: ${node_ip} 不存在cmdb中，检查次数:${count}"
                else
                        echoE "机器: ${node_ip} 已在cmdb存在"
                        sign=1
                        break
                fi
                sleep 30
                count=$((count+1))

        done

    if [ $sign == 0  ]
    then
        echoE "机器: ${node_ip} 不存在cmdb,DNS 更新失败"
        echoE "再次写入默认初始化内容"
        init_conf
        return 1
    fi

        node_contant=` /usr/bin/curl  -H "Authorization: REDACTED_AUTHORIZATION" -s ${url_cmdb_node}   `
        echoE "获取机器cmdb 信息:${node_contant}"

        workspace_name=`/usr/bin/curl  -H "Authorization: REDACTED_AUTHORIZATION" -s ${url_cmdb_node}  | /usr/bin/python -c "import sys, json; print(json.load(sys.stdin)[0].get('workspace','')) "`


        if [ $workspace_name  ]
        then
                # url_cmdb_cell="https://endpoint-03.example.invalid/cmdb-api/v1-0/cell/all?code=${workspace_name}"
                # dns_strings=`/usr/bin/curl  -H "Authorization: REDACTED_AUTHORIZATION" -s ${url_cmdb_cell}    | /usr/bin/python -c "import sys, json; print(json.load(sys.stdin)[0].get('dns')) "`

                url_cmdb_workspace="https://endpoint-02.example.invalid/cmdb-api/v1-0/commondata/md_workspace?sort_field=&sort_flag&code=${workspace_name}"
                vdccode=`/usr/bin/curl  -H "Authorization: REDACTED_AUTHORIZATION"  -s ${url_cmdb_workspace}   | /usr/bin/python -c "import sys, json; print(json.load(sys.stdin).get('data')[0].get('vdc'))"`
                echoE "workspace 的vdccode 值为:${vdccode}"

                url_cmdb_workspace_vdc="https://endpoint-02.example.invalid/cmdb-api/v1-0/commondata/md_vdc?sort_field=&sort_flag=&page=1&size=15&code=${vdccode}"
                dns_strings=`/usr/bin/curl  -H "Authorization: REDACTED_AUTHORIZATION"  -s ${url_cmdb_workspace_vdc}  | /usr/bin/python -c "import sys, json; print(json.load(sys.stdin).get('data')[0].get('dns'))"`

                request_result=$?
                if [ $request_result -ne 0 ]
                then
                        echoE "DNS 列表获取失败"
                        return 1
                fi
                dns_env_arr=`echo ${dns_strings} | sed 's/,/ /g'`
                if [ "$dns_env_arr" == "None" ]
                then
                        echoE "DNS 列表获取失败，为：${dns_env_arr}"
                        return 1
                fi

                echoE "单元名称:${workspace_name}  dns 列表:${dns_env_arr}"
                echo "options timeout:1 attempts:2" > /etc/resolv.conf

            for denv in ${dns_env_arr}
            do
                echo "nameserver ${denv}" >> /etc/resolv.conf
            done
            echoE "写入DNS列表：${dns_env_arr}"
        else
                echoE "未成功获取到单元名称:${workspace_name}"
                return 1
        fi

}

function main(){
        echoE "######################################"
        echoE "python 环境检查"
        pythonenv

        cp -a  /etc/resolv.conf /etc/resolv.conf_bak_`date   +"%Y%m%d_%H%M"`

        cat /etc/os-release  |egrep -i "Debian|Ubuntu"  &>/dev/null
        if [ $? -eq 0 ]
        then
                echoE "debian 系操作系统，进行相关的设置"
                debianSet
        fi

        /usr/bin/chattr -iae  /etc/resolv.conf
        echoE "打开/etc/resolv.conf 文件锁"

        echoE "进���初始化配置:192.0.2.1  192.0.2.3"
        init_conf

        echoE "更新DNS配置"
        if [ $workspace_code  ]
        then
                echoE "传入的workspace 为：$workspace_code"
                update_vdc_conf
        else
                echoE "未传入的workspace"
                update_conf
        fi

        if [ $? -eq 1 ]
        then
                echoE "更新DNS失败"
                exit 1
        else
                echoE "更新DNS成功"
        fi
        echoE "`cat /etc/resolv.conf`"
        /usr/bin/chattr +i /etc/resolv.conf
        echoE "关闭/etc/resolv.conf 文件锁"

}

main

