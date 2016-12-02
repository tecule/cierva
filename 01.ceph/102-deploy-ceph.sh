#!/bin/sh

###
### deploy openstack ha cluster 
### 
### run from the admin node
### run as deploy user
###

. ../000-common.sh

file_full_name=`basename "$0"`
file_extension="${file_full_name##*.}"
file_name="${file_full_name%.*}"
log_file="/tmp/"$file_name".log"

echo > $log_file

function deploy_ceph() {
    echo -n "确认已经切换到部署用户，按任意键继续[-]"
    read answer

    cd

    ### [admin节点] 配置部署用户到所有节点的无密码ssh访问
    echo "=== TRACE MESSAGE ===>>> " "配置部署用户到所有节点的无密码ssh访问" | tee -a $log_file
    ssh-keygen
    for h in ${ceph_admin_mons_osds[@]};
    do    
        ssh-copy-id $ceph_deploy_user@$h
    done

    ### [admin节点] 配置部署用户的~/.ssh/config文件
    echo "=== TRACE MESSAGE ===>>> " "配置部署用户的~/.ssh/config文件" | tee -a $log_file
    echo > /tmp/ssh_config
    for h in ${ceph_admin_mons_osds[@]};
    do    
        echo "Host $h" >> /tmp/ssh_config
        echo "   Hostname $h" >> /tmp/ssh_config
        echo "   User $ceph_deploy_user" >> /tmp/ssh_config
    done
    cp /tmp/ssh_config ~/.ssh/config
    chmod 600 .ssh/config

    ### [admin节点] 创建部署目录
    echo "=== TRACE MESSAGE ===>>> " "创建部署目录" | tee -a $log_file
    mkdir ~/ceph-cluster
    cd ~/ceph-cluster

    ### [admin节点] 创建集群，参数中的节点是monitor节点，命令生成ceph配置文件和一个keyring
    echo "=== TRACE MESSAGE ===>>> " "创建集群" | tee -a $log_file
    ceph-deploy new ${ceph_mons[@]} >> $log_file 2>&1

    ### [admin节点] 修改ceph.conf文件
    echo "=== TRACE MESSAGE ===>>> " "修改ceph.conf文件" | tee -a $log_file
    sed \
        -e "s/CEPH_PUBLIC_NETWORK/$ceph_public_network\/$ceph_public_network_prefix/" \
        -e "s/CEPH_CLUSTER_NETWORK/$ceph_cluster_network\/$ceph_cluster_network_prefix/" \
        /tmp/ceph.conf.suffix > /tmp/ceph.conf.suffix.2
    cat /tmp/ceph.conf.suffix.2 | tee -a ceph.conf > /dev/null

    for h in ${ceph_admin_mons_osds[@]};
    do
        ### [所有节点] 安装ceph，包括admin节点和ceph节点，在admin节点上安装ceph是为了使用CLI。不用ceph-deploy安装，因为它会下载epel-release，并试图通过网络安装。
        echo "=== TRACE MESSAGE ===>>> " $h ": 安装ceph" | tee -a $log_file
        ssh $h sudo yum install -y ceph >> $log_file
    done    
    
    ### [admin节点] 初始化monitor
    # 必要时修改monitor节点的服务unit名称
    # ssh compute01 sudo mv /usr/lib/systemd/system/ceph-mon@.service /usr/lib/systemd/system/ceph-mon@compute01.service
    echo "=== TRACE MESSAGE ===>>> " "初始化monitor" | tee -a $log_file
    ceph-deploy mon create-initial >> $log_file 2>&1

    for h in ${ceph_osds[@]};
    do
        # 必要时修改目录属主：ERROR: error creating empty object store in /disk2: (13) Permission denied
        echo "=== TRACE MESSAGE ===>>> " $h ": 修改OSD目录的属主" | tee -a $log_file
        ssh $h sudo chown ceph:ceph -R ${ceph_osd_disks[@]}
    done

    ### [admin节点] 添加OSD，参数中的节点是ceph节点
    echo "=== TRACE MESSAGE ===>>> " "添加OSD：准备" | tee -a $log_file
    ceph-deploy osd prepare $ceph_osd_host_disk_list >> $log_file 2>&1
    echo "=== TRACE MESSAGE ===>>> " "添加OSD：激活" | tee -a $log_file
    ceph-deploy osd activate $ceph_osd_host_disk_list >> $log_file 2>&1

    ### [admin节点] 拷贝配置文件和admin key到所有节点，参数中的节点包括admin节点和ceph节点
    echo "=== TRACE MESSAGE ===>>> " "拷贝配置文件和admin key到所有节点" | tee -a $log_file
    ceph-deploy admin $ceph_admin_mons_osds >> $log_file 2>&1

    ### [admin节点] 为部署用户设置admin key的文件权限。root用户已经有权限，不需要设置。
    echo "=== TRACE MESSAGE ===>>> " "为部署用户设置admin key的文件权限" | tee -a $log_file
    sudo chmod +r /etc/ceph/ceph.client.admin.keyring
}

echo -n "confirm to deploy ceph [y|n]"
read answer
if [ $answer == "y" ]; then
    deploy_ceph
fi