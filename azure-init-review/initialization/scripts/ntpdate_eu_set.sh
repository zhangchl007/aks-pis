#!/bin/bash

log_file="/var/log/ntp_set.log"
echo > $log_file
function echoE(){
        start_current_date="`date "+%Y-%m-%d %H:%M:%S"`"
        echo  ${start_current_date}  ${@}  >> $log_file
}



function clean_old_crontab(){
        CrontFile="/var/spool/cron/root"
        echoE "清除历史ntp定时任务"
        systemctl stop ntpd && systemctl disable ntpd
        sed -i  '/endpoint-09.example.invalid/ d'  ${CrontFile}
        sed -i  '/endpoint-08.example.invalid/ d'  ${CrontFile}
}


function deployChrony(){
        # 调整配置文件
        #sed -i.bak  's/^server.*iburst/server endpoint-08.example.invalid  iburst/'   /etc/chrony.conf
	sed -i.bak    -e   's/^server/#server/g' -e 's/^pool/#pool/g'  -e  '/endpoint-08.example.invalid/ d'  /etc/chrony.conf
        echo "server endpoint-05.example.invalid  iburst" >>  /etc/chrony.conf

        # 启动服务
        systemctl restart chronyd && systemctl enable chronyd
        systemctl status  chronyd
        if [ $? -eq 0 ]
        then 
                echoE "启动 chronyd 服务-完成"
        else
                echoE "启动 chronyd 服务-失败"
                exit 1
        fi 

        # 时间同步的情况
        chronyc  sources -vn |egrep "192.0.2.4|192.0.2.5"
                if [ $? -eq 0 ]
        then 
                echoE "chronyd 服务正常"
        else
                echoE "chronyd 服务异常"
                #exit 1
        fi 
        

        # 清理老的定时任务
        clean_old_crontab
        echoE "清理老的定时任务完成"
}
deployChrony

