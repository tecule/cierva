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

function install_galera() {
    for c in ${controllers[@]};
    do
        ### [所有控制节点] 修改/etc/haproxy/haproxy.cfg文件，采用httpchk
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/haproxy/haproxy.cfg文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen galera_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:3306" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option httpchk" >> /etc/haproxy/haproxy.cfg
EOF
        for ((i=0; i<${#controllers[@]}; i+=1));
        do
            name=${controllers[$i]};
            ip=${controller_mgmt_nic_map[$name]};
            if [ $i -eq 0 ]; then
                echo "    server $name $ip:3306 check port 9200 inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
            else
                echo "    server $name $ip:3306 backup check port 9200 inter 2000 rise 2 fall 5"  | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
            fi
        done;
    
        ### [所有控制节点]安装软件，galera included in mariadb server since 10.1
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件" | tee -a $log_file
        ssh $c yum install -y MariaDB-server xinetd >> $log_file

        ### [所有控制节点]修改/etc/my.cnf.d/server.cnf文件
        # bind-address不能设定为0.0.0.0，否则会绑定VIP的端口，导致HAProxy无法启动
        # 以wsrep_开头的配置项是Galera Cluster配置参数
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/my.cnf.d/server.cnf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
cat >> /etc/my.cnf.d/server.cnf << EOF2
datadir=/var/lib/mysql
socket=/var/lib/mysql/mysql.sock
user=mysql
binlog_format=ROW
bind-address=${controller_mgmt_nic_map[$c]}

default_storage_engine=innodb
innodb_autoinc_lock_mode=2
innodb_flush_log_at_trx_commit=0
innodb_buffer_pool_size=122M

wsrep_on=ON
wsrep_provider=/usr/lib64/galera/libgalera_smm.so
wsrep_provider_options="pc.recovery=TRUE;gcache.size=300M"
wsrep_cluster_name="galera_cluster"
wsrep_cluster_address="gcomm://$controller_list_comma"
wsrep_node_name=$c
wsrep_node_address=${controller_mgmt_nic_map[$c]}
wsrep_sst_method=rsync
EOF2

EOF
    done;

    ### [controller01] 在一个节点初始化Primary Component，Primary Component是仲裁里的多数派，相互之间进行数据复制。
    echo "=== TRACE MESSAGE ===>>> " "在一个节点初始化Primary Component" | tee -a $log_file
    galera_new_cluster

    ### [controller01] 等待mariadb服务启动
    echo "=== TRACE MESSAGE ===>>> " "等待mariadb服务启动，然后按任意键继续 ...... ...... ...... [-]" | tee -a $log_file
    read answer

    ### [controller01以外的节点] 启动数据库，由于设定了wsrep_cluster_address，其他节点默认加入一个已经存在的Primary Component
    echo "=== TRACE MESSAGE ===>>> " "其他节点默认加入一个已经存在的Primary Component" | tee -a $log_file
    for ((i=1; i<${#controllers[@]}; i+=1));
    do 
        ssh ${controllers[$i]} systemctl start mariadb
    done;

    for c in ${controllers[@]};
    do
    ### [所有控制节点]初始化/etc/sysconfig/clustercheck文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 初始化/etc/sysconfig/clustercheck文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            echo MYSQL_USERNAME=\"$clustercheck_username\" > /etc/sysconfig/clustercheck
            echo MYSQL_PASSWORD=\"$clustercheck_password\" >> /etc/sysconfig/clustercheck
            echo MYSQL_HOST=\"localhost\" >> /etc/sysconfig/clustercheck
            echo MYSQL_PORT=\"3306\" >> /etc/sysconfig/clustercheck
EOF
    done;

    ### [controller01] 设置数据库访问权限
    echo "=== TRACE MESSAGE ===>>> " "设置数据库访问权限" | tee -a $log_file
    mysql -uroot -e "GRANT PROCESS ON *.* TO '$clustercheck_username'@'localhost' IDENTIFIED BY '$clustercheck_password';";
    mysql -uroot -e "FLUSH PRIVILEGES;";

    for c in ${controllers[@]};
    do
        ### [所有控制节点] 初始化/etc/xinetd.d/galera-monitor文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 初始化/etc/xinetd.d/galera-monitor文件" | tee -a $log_file
        scp galera/galera-monitor $c:/etc/xinetd.d/galera-monitor >> $log_file

        ###  [所有控制节点]初始化/usr/bin/clustercheck脚本
        echo "=== TRACE MESSAGE ===>>> " $c ": 初始化/usr/bin/clustercheck脚本" | tee -a $log_file
        scp galera/clustercheck $c:/tmp/clustercheck >> $log_file
        ssh $c /bin/bash << EOF
            sed -i \
                -e "s/CLUSTERCHECK_USERNAME/$clustercheck_username/" \
                -e "s/CLUSTERCHECK_PASSWORD/$clustercheck_password/" \
                /tmp/clustercheck

            cp /tmp/clustercheck /usr/bin/clustercheck
            chmod a+x /usr/bin/clustercheck
EOF

        ### [所有控制节点]配置服务
        echo "=== TRACE MESSAGE ===>>> " $c ": 配置服务" | tee -a $log_file
        ssh $c systemctl daemon-reload
        ssh $c systemctl enable xinetd
        ssh $c systemctl start xinetd
    done;
}

echo -n "confirm to install galera [y|n]"
read answer
if [ $answer == "y" ]; then
    install_galera
fi
