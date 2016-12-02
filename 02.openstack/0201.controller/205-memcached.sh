#!/bin/sh

###
### deploy openstack ha cluster 
### 
### run from the first controller node
###

. ../../000-common.sh

file_full_name=`basename "$0"`
file_extension="${file_full_name##*.}"
file_name="${file_full_name%.*}"
log_file="/tmp/"$file_name".log"

echo > $log_file

function install_memcached() {
    for c in ${controllers[@]};
    do
        ### [所有控制节点]安装软件，配置服务
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件，配置服务" | tee -a $log_file
        ssh $c /bin/bash << EOF
            yum install -y memcached >> $log_file

            systemctl enable memcached.service >> $log_file
            systemctl start memcached.service
EOF
    done;
}

echo -n "confirm to install memcached [y|n]"
read answer
if [ $answer == "y" ]; then
    install_memcached
fi

