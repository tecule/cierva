#!/bin/sh

###
### deploy openstack ha cluster 
### 
### run from the admin node
### run as root
###

. ../000-common.sh

file_full_name=`basename "$0"`
file_extension="${file_full_name##*.}"
file_name="${file_full_name%.*}"
log_file="/tmp/"$file_name".log"

echo > $log_file

function prepare_ceph() {
    for h in ${ceph_admin_mons_osds[@]};
    do
        ### [所有节点] 配置部署用户，配置admin节点是因为ceph-deploy admin命令需要用到。ceph-deploy以该用户无密码远程ssh到ceph节点上，然后通过无密码sudo进行安装和配置。
        echo "=== TRACE MESSAGE ===>>> " $h ": 配置部署用户" | tee -a $log_file
        ssh $h /bin/bash << EOF
            useradd $ceph_deploy_user
            echo "123456" | passwd --stdin $ceph_deploy_user
             
            echo "$ceph_deploy_user ALL = (root) NOPASSWD:ALL" | tee /etc/sudoers.d/$ceph_deploy_user
            chmod 0440 /etc/sudoers.d/$ceph_deploy_user
EOF

        ### [所有节点] 配置visudo，配置admin节点是因为ceph-deploy admin命令需要用到。注释掉requiretty，允许sudo within scripts。
        echo "=== TRACE MESSAGE ===>>> " $h ": 配置visudo" | tee -a $log_file
        ssh $h /bin/bash << EOF        
            sed -i s'/Defaults    requiretty/# Defaults    requiretty'/g /etc/sudoers
EOF
    done

    ### [admin节点] 安装ceph-deploy，使用ceph源中的ceph-deploy，不要用epel库里的
    echo "=== TRACE MESSAGE ===>>> " "安装ceph-deploy" | tee -a $log_file
    yum --disablerepo=\* --enablerepo=$ceph_deploy_repo install -y ceph-deploy >> $log_file

    for h in ${ceph_mons_osds[@]};
    do
        ### [ceph节点] 安装yum-plugin-priorities
        echo "=== TRACE MESSAGE ===>>> " $h ": 安装yum-plugin-priorities" | tee -a $log_file
        ssh $h yum install -y yum-plugin-priorities >> $log_file
    done

    ### [admin节点] 初始化ceph.conf.suffix
    echo "=== TRACE MESSAGE ===>>> " "初始化ceph.conf.suffix" | tee -a $log_file
    rm -f /tmp/ceph.conf.suffix
    cp ceph/ceph.conf.suffix /tmp/ceph.conf.suffix

    echo "=== TRACE MESSAGE ===>>> " "---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ----" | tee -a $log_file
    echo "=== TRACE MESSAGE ===>>> " "切换到部署用户，并执行102-deploy.sh" | tee -a $log_file
    echo "=== TRACE MESSAGE ===>>> " "---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ----" | tee -a $log_file
}

echo -n "confirm to prepare to install ceph [y|n]"
read answer
if [ $answer == "y" ]; then
    prepare_ceph
fi