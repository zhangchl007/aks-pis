#!/bin/bash
#set -e

log_file="/var/log/sre_ntp_set.log"
echo > $log_file
function echoE(){
        start_current_date="`date "+%Y-%m-%d %H:%M:%S"`"
        echo  ${start_current_date}  ${@}  >> $log_file
}

function offChrony(){
        systemctl stop chronyd && systemctl disable chronyd
        echoE "关闭 chronyd 服务-完成"
}

# 老的方案
function installNtpDate() {
    echoE "安装ntpdate 命令"
    # centos 、rocky
    cat /etc/os-release|egrep  -i "centos|rocky" >>/dev/null
    if [ $? -eq 0 ]
    then
        cat /etc/os-release|egrep  -i "centos-8" >>/dev/null
        if [ $? -eq 0 ]
        then
                ntpdatePath="/usr/local/bin/ntpdate"
                rpm -ivh http://endpoint-04.example.invalid/centos/wlnmp-release-centos.noarch.rpm
                yum  install wntp -y >>/dev/null  && return 0 || return 1
        fi
        yum install ntpdate -y >>/dev/null  && return 0 || return 1
    fi

    # ubuntu  Debian
    cat /etc/os-release  |egrep  -i "Ubuntu 18" >>/dev/null
    if [ $? -eq 0 ]
    then
        apt-get install ntpdate -y   >>/dev/null  && return 0 || return 1
    fi

    cat /etc/os-release  |egrep  -i "Ubuntu 22|Ubuntu 24|Debian" >>/dev/null
    if [ $? -eq 0 ]
    then
	apt update
        apt install chrony -y
        sed -i.bak '1 a\pool endpoint-08.example.invalid iburst'   /etc/chrony/chrony.conf
        systemctl restart  chrony
        exit 0
    else
        return 1
    fi

}


# 老的方案
function setNtpCrontab(){
        CrontFile="/var/spool/cron/root"
        ntpserver="endpoint-08.example.invalid"

        offChrony
        echoE "添加前"
        cat -A   ${CrontFile}  >> ${log_file}

        echoE "检查机器ntpdate命令存在性"
        ntpdatePath=`which ntpdate`
        if [ $? -ne  0 ]
        then
                echoE "机器ntpdate命令不存在"
                installNtpDate
                if [ $? -ne  0 ]
                then
                        echoE "ntpdate命令安装失败"
                        exit 1
                else
                        echoE "ntpdate命令安装成功"
                fi
        fi

        echoE "清除历史ntp定时任务"
        sed -i  '/endpoint-09.example.invalid/ d'  ${CrontFile}
        sed -i  '/endpoint-08.example.invalid/ d'  ${CrontFile}


        echoE "添加ntp 定时任务"
        echo "*/5 * * * * ${ntpdatePath} ${ntpserver} >/dev/null 2>&1" > ${CrontFile}
        echoE "添加后"
        cat -A   ${CrontFile}  >> ${log_file}
}


function  install_chronyd(){
    # ubuntu  Debian
    apt-get update
    cat /etc/os-release  |egrep  -i "Ubuntu 18" >>/dev/null
    if [ $? -eq 0 ]
    then
        apt-get install chrony -y   >>/dev/null  && return 0 || return 1
    fi

    cat /etc/os-release  |egrep  -i "Ubuntu 22|Ubuntu 24|Debian" >>/dev/null
    if [ $? -eq 0 ]
    then
        apt install chrony -y
    else
        return 1
    fi

}

function clean_old_crontab(){
        CrontFile="/var/spool/cron/root"
        if [ -f $CrontFile ]
        then 
                echoE "清除历史ntp定时任务"
                #sed -i  '/endpoint-09.example.invalid/ d'  ${CrontFile}
                #sed -i  '/endpoint-08.example.invalid/ d'  ${CrontFile}
                sed -i.bak -e  '/endpoint-09.example.invalid/ d' -e  '/endpoint-08.example.invalid/ d'  ${CrontFile}
        else
                echoE "ntp定时任务$CrontFile 文件不存在"
        fi
}


function deployChrony(){
        # ubuntu 安装chrony
        chronyd -v 2>&1 >/dev/null
        if [ $?  -ne 0 ] 
        then
                echoE "chronyd 未安装，进行chronyd安装"
                cat  /etc/os-release
                install_chronyd
        fi
        

        # 调整配置文件
        #sed -i.bak  's/^server.*iburst/server endpoint-08.example.invalid  iburst/'   /etc/chrony.conf

        cat /etc/os-release  |egrep  -i "Ubuntu|Debian" >>/dev/null
        
        if [[ $? -eq 0  &&  -f /etc/chrony/chrony.conf ]]
        then 
                sed -i.bak    -e   's/^server/#server/g'  -e 's/^pool/#pool/g'   -e  '/endpoint-08.example.invalid/ d'  /etc/chrony/chrony.conf
                echo "server endpoint-08.example.invalid  iburst" >>  /etc/chrony/chrony.conf

        elif [ -f /etc/chrony.conf  ]
        then 
                sed -i.bak    -e   's/^server/#server/g'  -e 's/^pool/#pool/g'   -e  '/endpoint-08.example.invalid/ d'  /etc/chrony.conf
                echo "server endpoint-08.example.invalid  iburst" >>  /etc/chrony.conf
        else
                echoE "配置文件不存在，配置失败"
                exit 1
        fi




        # 启动服务
        systemctl restart chronyd || systemctl restart chrony
        systemctl enable chronyd  || systemctl enable  chrony
        echoE "启动 chronyd 服务-完成"

        # 时间同步的情况
        echoE `chronyc  sources -vn `

        # 清理老的定时任务
        clean_old_crontab
        echoE "清理老的定时任务完成"
}
deployChrony

