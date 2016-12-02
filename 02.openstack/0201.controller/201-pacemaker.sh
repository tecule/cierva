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

function install_pacemaker() {
    for c in ${controllers[@]};
    do
        ### [所有控制节点] 安装软件
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件" | tee -a $log_file
        ssh $c yum install -y pacemaker pcs corosync fence-agents-all resource-agents >> $log_file
    
        ### [所有控制节点] 配置服务
        echo "=== TRACE MESSAGE ===>>> " $c ": 配置服务" | tee -a $log_file
        ssh $c systemctl enable pcsd >> $log_file
        ssh $c systemctl start pcsd >> $log_file
    
        ### [所有控制节点]设置hacluster用户的密码
        echo "=== TRACE MESSAGE ===>>> " $c ": 设置hacluster用户的密码" | tee -a $log_file
        ssh $c /bin/bash << EOF 
            echo $hacluster_password | passwd --stdin hacluster
EOF
    done;
    
    ### [controller01]设置到集群节点的认证
    echo "=== TRACE MESSAGE ===>>> " "设置到集群节点的认证" | tee -a $log_file
    pcs cluster auth $controller_list_space -u hacluster -p $hacluster_password --force >> $log_file
    
    ### [controller01]创建并启动集群 
    echo "=== TRACE MESSAGE ===>>> " "创建并启动集群" | tee -a $log_file
    pcs cluster setup --force --name $controller_cluster_name $controller_list_space >> $log_file
    pcs cluster start --all >> $log_file
    
    ### [controller01]设置集群属性
    echo "=== TRACE MESSAGE ===>>> " "设置集群属性" | tee -a $log_file
    pcs property set pe-warn-series-max=1000 pe-input-series-max=1000 pe-error-series-max=1000 cluster-recheck-interval=5min
    
    ### [controller01] 禁用STONISH，否则资源无法启动
    echo "=== TRACE MESSAGE ===>>> " "禁用STONISH" | tee -a $log_file
    pcs property set stonith-enabled=false
    
    ### [controller01]配置VIP资源，VIP可以在集群节点间浮动
    echo "=== TRACE MESSAGE ===>>> " "配置VIP资源，VIP可以在集群节点间浮动" | tee -a $log_file
    # netmask = 23
    pcs resource create virtual-ip ocf:heartbeat:IPaddr2 params ip=$virtual_ip cidr_netmask="23" op monitor interval="30s"
}

echo -n "confirm to install pacemaker [y|n]"
read answer
if [ $answer == "y" ]; then
    install_pacemaker
fi
