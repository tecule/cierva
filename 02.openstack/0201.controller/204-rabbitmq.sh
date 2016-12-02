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

function install_rabbitmq() {
    for c in ${controllers[@]};
    do
        ### [所有控制节点] 安装软件，设置用户和权限
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件，设置用户和权限" | tee -a $log_file
        ssh $c /bin/bash << EOF
            yum install -y rabbitmq-server >> $log_file

            # start rabbitmq server to create user
            systemctl start rabbitmq-server
            rabbitmqctl add_user $rabbitmq_username $rabbitmq_password >> $log_file
            rabbitmqctl set_permissions $rabbitmq_username ".*" ".*" ".*" >> $log_file
            # stop rabbitmq server before receive cookie from controller01
            systemctl stop rabbitmq-server
EOF
    done;

    ###
    ### http://docs.openstack.org/ha-guide/shared-messaging.html
    ### We have to consider that, while exchanges and bindings survive the loss of individual nodes, 
    ### queues and their messages do not because a queue and its contents are located on one node. 
    ### If we lose this node, we also lose the queue.
    ###

    ### [controlloer01] 所有节点需要相同的Erlang coolie文件，拷贝cookie文件到其他节点
    echo "=== TRACE MESSAGE ===>>> " "拷贝cookie文件到其他节点" | tee -a $log_file
    for ((i=1; i<${#controllers[@]}; i+=1));
    do
        scp /var/lib/rabbitmq/.erlang.cookie ${controllers[$i]}:/var/lib/rabbitmq/.erlang.cookie
    done;

    for c in ${controllers[@]};
    do
        ### [所有控制节点] 修改cookie文件的权限，配置rabbitmq-server服务
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改cookie文件的权限，配置rabbitmq-server服务" | tee -a $log_file
        ssh $c /bin/bash << EOF
            chown rabbitmq:rabbitmq /var/lib/rabbitmq/.erlang.cookie
            chmod 400 /var/lib/rabbitmq/.erlang.cookie

            systemctl enable rabbitmq-server.service >> $log_file
            systemctl start rabbitmq-server.service
EOF
    done;

    for ((i=1; $i<${#controllers[@]}; i+=1));
    do
        ### [controller01以外的节点] 加入集群 
        echo "=== TRACE MESSAGE ===>>> " ${controllers[$i]} ": 加入集群" | tee -a $log_file
        ssh ${controllers[$i]} /bin/bash << EOF
            rabbitmqctl stop_app >> $log_file
            rabbitmqctl join_cluster --ram rabbit@$controller_0 >> $log_file
            rabbitmqctl start_app >> $log_file
EOF
    done;

    ### [controlloer01] 设置ha-mode，配置queue为mirrored，Mirrored queues会把queue保存在所有节点
    echo "=== TRACE MESSAGE ===>>> " "设置ha-mode" | tee -a $log_file
    rabbitmqctl set_policy ha-all '^(?!amq\.).*' '{"ha-mode": "all"}' >> $log_file
}

echo -n "confirm to install rabbitmq [y|n]"
read answer
if [ $answer == "y" ]; then
    install_rabbitmq
fi
