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

function install_openstack_prerequisites() {
    for n in ${networks[@]};
    do
        ### [所有网络节点] 安装软件
        echo "=== TRACE MESSAGE ===>>> " $n ": 安装软件" | tee -a $log_file
        ssh $n yum install -y python-openstackclient openstack-selinux openstack-utils >> $log_file
    done;
}

echo -n "confirm to install openstack prerequisites [y|n]"
read answer
if [ $answer == "y" ]; then
    install_openstack_prerequisites
fi
