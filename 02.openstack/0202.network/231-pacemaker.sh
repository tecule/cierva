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
    for n in ${networks[@]}
    do
        ### [所有网络节点] 安装软件
        echo "=== TRACE MESSAGE ===>>> " $n ": 安装软件" | tee -a $log_file
        ssh $n yum install -y pacemaker pcs corosync fence-agents-all resource-agents >> $log_file
    
        ### [所有网络节点] 配置服务
        echo "=== TRACE MESSAGE ===>>> " $n ": 配置服务" | tee -a $log_file
        ssh $n systemctl enable pcsd >> $log_file
        ssh $n systemctl start pcsd >> $log_file
    
        ### [所有网络节点]设置hacluster用户的密码
        echo "=== TRACE MESSAGE ===>>> " $n ": 设置hacluster用户的密码" | tee -a $log_file
        ssh $n /bin/bash << EOF 
            echo $hacluster_password | passwd --stdin hacluster
EOF
    done

    ### [network01]设置到集群节点的认证
    echo "=== TRACE MESSAGE ===>>> " $network_0 "设置到集群节点的认证" | tee -a $log_file
    ssh $network_0 /bin/bash << EOF
        pcs cluster auth $network_list_space -u hacluster -p $hacluster_password --force
EOF
        
    ### [network01]创建并启动集群 
    echo "=== TRACE MESSAGE ===>>> " $network_0 "创建并启动集群" | tee -a $log_file
    ssh $network_0 /bin/bash << EOF
        pcs cluster setup --force --name $network_cluster_name $network_list_space
        pcs cluster start --all
EOF
        
    ### [network01]设置集群属性
    echo "=== TRACE MESSAGE ===>>> " $network_0 "设置集群属性" | tee -a $log_file
    ssh $network_0 /bin/bash << EOF
        pcs property set pe-warn-series-max=1000 pe-input-series-max=1000 pe-error-series-max=1000 cluster-recheck-interval=5min
EOF
 
    ### [network01] 禁用STONISH，否则资源无法启动
    echo "=== TRACE MESSAGE ===>>> " $network_0 "禁用STONISH" | tee -a $log_file
    ssh $network_0 /bin/bash << EOF
        pcs property set stonith-enabled=false
EOF

    ### [network01] 禁用QUORUM
    echo "=== TRACE MESSAGE ===>>> " $network_0 "禁用QUORUM" | tee -a $log_file
    ssh $network_0 /bin/bash << EOF
        pcs property set stonith-enabled=false
EOF
}

echo -n "confirm to install pacemaker [y|n]"
read answer
if [ $answer == "y" ]; then
    install_pacemaker
fi
