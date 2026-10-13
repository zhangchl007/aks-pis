#!/bin/bash

log_file="/var/log/sre_user_init.log"
error_log_file="/var/log/sre_user_init_error.log"
touch ${log_file} &&  echo > ${log_file}
touch ${error_log_file} &&  echo > ${error_log_file}

function echoE(){
start_current_date="`date "+%Y-%m-%d %H:%M:%S"`"
echo ${start_current_date}  $1  >> $log_file
}


function addSudo() {
    # centos 、rocky
    cat /etc/os-release|egrep  -i "centos|rocky" >>/dev/null
    if [ $? -eq 0 ]
    then
        usermod -a -G wheel ${username}
        sed -i "s/Defaults    requiretty/#Defaults requiretty/g"  /etc/sudoers
        sed -i "s/# %wheel/%wheel/g"  /etc/sudoers
        return 0
    fi

    # ubuntu  Debian
    cat /etc/os-release|egrep  -i "ubuntu|Debian" >>/dev/null
    if [ $? -eq 0 ]
    then
        usermod -a -G sudo ${username}
        sed -i "/^%sudo/ d"  /etc/sudoers
        echo "%sudo   ALL=(ALL:ALL) NOPASSWD: ALL"  >> /etc/sudoers
        return 0
    fi

}

# User
function user_init() {
    username=$1
    id $username >>/dev/null
    if [ $? -eq 0 ]
    then
        echoE "用户${username}已存在，删除用户"
        userdel $username
    fi


    useradd  -K PASS_MAX_DAYS=-1  -s  /bin/bash  $username
    # Determine the user belongs to wheel

    mkdir  -p  /home/${username}/.ssh
    wget http://endpoint-01.example.invalid/initialization/config/user/${username}_id_rsa.pub -O /home/${username}/.ssh/authorized_keys
    chown ${username}:${username} /home/${username}/ -R
    chmod 600 /home/${username}/.ssh/authorized_keys

    wheel_arr="ops_admin sre_admin"
    iswheel=`echo ${wheel_arr} | grep ${username} | wc -l`
    if [ ${iswheel} -eq 1 ]; then
        addSudo
    fi


    id $username >>/dev/null
    if [ $? -eq 0 ]
    then
        echoE "用户初始化${username}-完成"
    else
        echoE "用户初始化${username}-失败"
    fi
}

function user_add() {
    echoE "用户初始化开始"
    add_list="app_user ops_admin sre_admin legacy_user"
    for user in ${add_list[@]}
    do
        user_init $user
    done
    echoE "用户初始化完成"
}

user_add

