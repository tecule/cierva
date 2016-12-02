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

function install_identity() {
    ### [controller01]删除数据库默认用户
    echo "=== TRACE MESSAGE ===>>> " "删除数据库默认用户" | tee -a $log_file
    # drop anonymous user, so keystone user can connect to database from `hostname`: '%' will work after this operation
    mysql -uroot -e "DROP USER ''@'localhost';"
    mysql -uroot -e "DROP USER ''@'`hostname`';"

    ### [controller01]创建数据库
    echo "=== TRACE MESSAGE ===>>> " "创建数据库" | tee -a $log_file
    mysql -uroot -e "CREATE DATABASE keystone;"
    # 
    mysql -uroot -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$keystone_db_password';"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$keystone_db_password';"
    mysql -uroot -e "FLUSH PRIVILEGES;"

    for c in ${controllers[@]};
    do
        ### [所有控制节点] 修改/etc/haproxy/haproxy.cfg文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/haproxy/haproxy.cfg文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen keystone_admin_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:35357" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  httpchk" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]};
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:35357 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done;

        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen keystone_public_internal_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:5000" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  httpchk" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]};
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:5000 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done;


        ### [所有控制节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件" | tee -a $log_file
        ssh $c yum install -y openstack-keystone httpd mod_wsgi >> $log_file
    done;

    ### [所有控制节点]生成临时token
    echo "=== TRACE MESSAGE ===>>> " "生成临时token" | tee -a $log_file
    export OS_TOKEN=`openssl rand -hex 10`
    echo "=== TRACE MESSAGE ===>>> " "OS_TOKEN = " $OS_TOKEN | tee -a $log_file

    for c in ${controllers[@]};
    do
        ### [所有控制节点]配置/etc/keystone/keystone.conf文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 配置/etc/keystone/keystone.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            openstack-config --set /etc/keystone/keystone.conf DEFAULT admin_token $OS_TOKEN
            openstack-config --set /etc/keystone/keystone.conf database connection mysql+pymysql://keystone:$keystone_db_password@$virtual_ip/keystone
            openstack-config --set /etc/keystone/keystone.conf token provider fernet

            openstack-config --set /etc/keystone/keystone.conf oslo_messaging_rabbit rabbit_hosts $rabbit_hosts_list
            openstack-config --set /etc/keystone/keystone.conf oslo_messaging_rabbit rabbit_ha_queues true
            openstack-config --set /etc/keystone/keystone.conf oslo_messaging_rabbit rabbit_retry_interval 1
            openstack-config --set /etc/keystone/keystone.conf oslo_messaging_rabbit rabbit_retry_backoff 2
            openstack-config --set /etc/keystone/keystone.conf oslo_messaging_rabbit rabbit_max_retries 0
            openstack-config --set /etc/keystone/keystone.conf oslo_messaging_rabbit rabbit_durable_queues true
EOF
    done;

    ### [controller01]初始化Fernet key，并共享给其他节点
    echo "=== TRACE MESSAGE ===>>> " "初始化Fernet key，并共享给其他节点" | tee -a $log_file
    keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
    for ((i=1; i<${#controllers[@]}; i+=1));
    do
        ssh ${controllers[$i]} mkdir -p /etc/keystone/fernet-keys/
        ssh ${controllers[$i]} chown keystone:keystone /etc/keystone/fernet-keys/
        ssh ${controllers[$i]} chmod 700 /etc/keystone/fernet-keys/
        scp /etc/keystone/fernet-keys/* ${controllers[$i]}:/etc/keystone/fernet-keys/ >> $log_file
        ssh ${controllers[$i]} chown keystone:keystone /etc/keystone/fernet-keys/*
    done;

    for c in ${controllers[@]};
    do
        ### [所有控制节点]修改/etc/httpd/conf/httpd.conf
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/httpd/conf/httpd.conf" | tee -a $log_file
        ssh $c /bin/bash << EOF
            sed -i -e "s/^#ServerName.*/ServerName $c/" /etc/httpd/conf/httpd.conf
EOF

        ### [所有控制节点]新建/etc/httpd/conf.d/wsgi-keystone.conf
        echo "=== TRACE MESSAGE ===>>> " $c ": 新建/etc/httpd/conf.d/wsgi-keystone.conf" | tee -a $log_file
        scp identity/wsgi-keystone.conf $c:/etc/httpd/conf.d/ >> $log_file
        ssh $c /bin/bash << EOF
            sed -i -e "s/^Listen 5000/Listen ${controller_mgmt_nic_map[$c]}:5000/" -e "s/^Listen 35357/Listen ${controller_mgmt_nic_map[$c]}:35357/" /etc/httpd/conf.d/wsgi-keystone.conf
EOF
    done;

    ### [controller01]生成fernet keys时日志文件属主是root，修改属主，否则生成数据库报错
    chown keystone:keystone /var/log/keystone/keystone.log

    ### [controller01]生成数据库
    echo "=== TRACE MESSAGE ===>>> " "生成数据库" | tee -a $log_file
    su -s /bin/sh -c "keystone-manage db_sync" keystone >> $log_file

    ### [controller01]添加pacemaker资源，openstack资源和haproxy资源无关，可以开启A/A模式
    echo "=== TRACE MESSAGE ===>>> " "添加pacemaker资源" | tee -a $log_file
    pcs resource create openstack-keystone systemd:httpd op start timeout=120 stop timeout=300 --clone interleave=true

    pcs constraint order start haproxy-clone then openstack-keystone-clone kind=Optional

    ### [controller01] 等待identity服务启动
    echo "=== TRACE MESSAGE ===>>> " "等待identity服务启动，确认服务在vip也开启监听，然后按任意键继续 ...... ...... ...... [-]" | tee -a $log_file
    read answer

    ### [controller01]设置临时环境变量
    echo "=== TRACE MESSAGE ===>>> " "设置临时环境变量" | tee -a $log_file
    export OS_URL=http://$virtual_ip:35357/v3
    export OS_IDENTITY_API_VERSION=3

    ### [controller01]service entity and API endpoints
    echo "=== TRACE MESSAGE ===>>> " "添加service entity" | tee -a $log_file
    openstack service create --name keystone --description "OpenStack Identity" identity >> $log_file

    echo "=== TRACE MESSAGE ===>>> " "添加API endpoints" | tee -a $log_file
    openstack endpoint create --region RegionOne identity public http://$virtual_ip:5000/v3 >> $log_file
    openstack endpoint create --region RegionOne identity internal http://$virtual_ip:5000/v3 >> $log_file
    openstack endpoint create --region RegionOne identity admin http://$virtual_ip:35357/v3 >> $log_file

    ### [controller01]创建项目和用户
    echo "=== TRACE MESSAGE ===>>> " "创建项目、用户和角色" | tee -a $log_file
    openstack domain create --description "Default Domain" default >> $log_file
    openstack project create --domain default --description "Admin Project" admin >> $log_file
    openstack user create --domain default --password $keystone_admin_password admin >> $log_file
    openstack role create admin >> $log_file
    openstack role add --project admin --user admin admin >> $log_file
    # user role for dashboard
    openstack role create user >> $log_file
    # enable get domain-scoped token for admin user
    openstack role add --domain default --user admin admin >> $log_file

    ### [controller01]创建service项目
    echo "=== TRACE MESSAGE ===>>> " "创建service项目" | tee -a $log_file
    openstack project create --domain default --description "Service Project" service >> $log_file

    for c in ${controllers[@]};
    do
        ### [所有控制节点]修改/etc/keystone/keystone-paste.ini，从[pipeline:public_api], [pipeline:admin_api], [pipeline:api_v3]删除admin_token_auth
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/keystone/keystone-paste.ini" | tee -a $log_file
        ssh $c /bin/bash << EOF
            sed -i -e "s/^pipeline = cors sizelimit url_normalize request_id admin_token_auth build_auth_context token_auth json_body ec2_extension public_service/pipeline = cors sizelimit url_normalize request_id build_auth_context token_auth json_body ec2_extension public_service/" \
            -e "s/^pipeline = cors sizelimit url_normalize request_id admin_token_auth build_auth_context token_auth json_body ec2_extension s3_extension admin_service/pipeline = cors sizelimit url_normalize request_id build_auth_context token_auth json_body ec2_extension s3_extension admin_service/" \
            -e "s/^pipeline = cors sizelimit url_normalize request_id admin_token_auth build_auth_context token_auth json_body ec2_extension_v3 s3_extension service_v3/pipeline = cors sizelimit url_normalize request_id build_auth_context token_auth json_body ec2_extension_v3 s3_extension service_v3/" \
            /etc/keystone/keystone-paste.ini
EOF
    done;

    ### [controller01]生成keystonerc_admin脚本
    echo "=== TRACE MESSAGE ===>>> " "生成keystonerc_admin脚本" | tee -a $log_file
    unset OS_TOKEN OS_URL
    cp identity/keystonerc_admin /root/keystonerc_admin >> $log_file
    sed -i -e "s/KEYSTONE_ADMIN_PASSWORD/$keystone_admin_password/" -e "s/VIRTUAL_IP/$virtual_ip/" /root/keystonerc_admin
}

echo -n "confirm to install identity [y|n]"
read answer
if [ $answer == "y" ]; then
    install_identity
fi

