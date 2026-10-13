#!/bin/bash

init_log="/data/logs/delete_log.log"
touch ${init_log} 

function echoE(){
start_current_date="`date "+%Y-%m-%d %H:%M:%S"`"
echo ${start_current_date}  $@  >> $init_log
}

function delLog(){
  echoE "########开始删除日志###########"
  delogtime=`date "+%Y-%m-%d %T"`
  delDay="2"
  delDump="180"
  dirList="
  /company/logs/
  /company/data/log/
  /company/data/logs/
  /data/logs/
  /data/log/
  /company/logs/logdelrecord/
  "

  delete_log_record_dir="/var/log/logdelrecord/"
  if [ ! -d  $delete_log_record_dir ]; then
    mkdir -p $delete_log_record_dir
  fi
  logDir="${delete_log_record_dir}`date "+%Y%m%d"`.log"


  # 匹配的日志格式定义
  del_log_format="\.log$|log\.zip$|log\..*zip$|log\.[0-9_-]+$|log\.gz$"
  del_log_long="dump.prof\.[0-9]+$"

  for dir in $dirList
  do
      if [  -d  $dir ]
      then 
        #find $dir -mtime +${delDay} |grep -E '(201|202|203|204|205)'|grep log|xargs rm -fv |sed "s#^#${delogtime} : delete log record : #g" >>$logDir
        find $dir -mtime +${delDay}  -type f |egrep $del_log_format |xargs rm -fv |sed "s#^#${delogtime} : delete log record : #g" >>$init_log
        find $dir -mtime +${delDump}  -type f |egrep $del_log_long |xargs rm -fv |sed "s#^#${delogtime} : delete log record : #g" >>$init_log
        echoE "目录${dir} 清理完成" 
      else
        echoE "目录${dir} 不存在" 
      fi
  done


  journalctl --vacuum-size=1G
  journalctl --vacuum-time=3d

}

function crontabCheck(){
  echoE ""
  echoE "开始检查日志删除配置"
  cat /etc/os-release |grep -i  Debian &>/dev/null
  if [ $? -eq 0 ]
  then 
    crontFilePath="/var/spool/cron/crontabs/root"
    echoE "系统为:Debian crontab 路径为:${crontFilePath}"
  else
    crontFilePath="/var/spool/cron/root"
    echoE "系统为:非Debian, 路径为:${crontFilePath}"
  fi 

  crontabExecStr='10 */1 * *  *  /bin/bash /company/devops/del_log.sh >/dev/null 2>&1'
  egrep del_log.sh $crontFilePath &>/dev/null 
  if [ $? -ne 0 ]
  then
    echoE "del_log.sh 未在crontab 配置，将增加相关配置到crontab"
    echo "$crontabExecStr" >> $crontFilePath
  else 
    echoE "del_log.sh 在crontab 已配置"
  fi

  if [ ! -f /company/devops/del_log.sh  ]
  then 
    echoE "/company/devops/del_log.sh 不存在，将下载此脚本"
    wget -O /company/devops/del_log.sh  http://endpoint-01.example.invalid:9090/scripts/del_log.sh  
  else
    echoE "/company/devops/del_log.sh 存在"
  fi 
}

delLog
crontabCheck


