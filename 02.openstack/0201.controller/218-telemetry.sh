#!/bin/sh

###
### deploy openstack ha cluster 
### 
### run from the first controller node
###

. ../../000-common.sh

. /root/keystonerc_admin

file_full_name=`basename "$0"`
file_extension="${file_full_name##*.}"
file_name="${file_full_name%.*}"
log_file="/tmp/"$file_name".log"

echo > $log_file

function install_telemetry() {
    #
    # metering服务
    #

    echo "=== TRACE MESSAGE ===>>> " "安装metering服务..." | tee -a $log_file

    for c in ${controllers[@]};
    do
        ### [所有控制节点] 安装MongoDB数据库
        echo "=== TRACE MESSAGE ===>>> " $c "安装MongoDB数据库" | tee -a $log_file
        ssh $c yum install -y mongodb-server mongodb >> $log_file

        ### [所有控制节点] 修改/etc/mongod.conf配置文件，所有节点的replSet设为同一个值
        echo "=== TRACE MESSAGE ===>>> " $c "修改/etc/mongod.conf配置文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            sed -i \
                -e 's#.*bind_ip.*#bind_ip = 0.0.0.0#g' \
                -e 's/.*replSet.*/replSet = ceilometer/g' \
                -e 's/.*smallfiles.*/smallfiles = true/g' \
                /etc/mongod.conf

            ### [所有控制节点] bootstrap数据库
            systemctl start mongod >> $log_file
            systemctl stop mongod                
EOF
    done

    ### [controller01] 添加pacemaker资源
    echo "=== TRACE MESSAGE ===>>> " "添加pacemaker资源" | tee -a $log_file
    pcs resource create mongod systemd:mongod op start timeout=300 stop timeout=300  --clone

    ### [controller01] 等待所有节点上的mongod服务启动
    echo "=== TRACE MESSAGE ===>>> " "等待所有节点上的mongod服务启动，然后按任意键继续 ...... ...... ...... [-]" | tee -a $log_file
    read answer

    ### [controller01] 设置mongodb副本集，等待所有节点启动mongod服务后
    # 生成mongodb配置文件
    echo "=== TRACE MESSAGE ===>>> " "设置mongodb副本集" | tee -a $log_file
    echo -n 'config = { _id:"ceilometer", members: [ ' > /root/mongo_replica_setup.js
    for ((i=0;i<${#controllers[@]};i+=1));
    do
            if [ $i -lt `expr ${#controllers[@]} - 1` ]; then
                    echo -n '{ _id: '$i', host: "'${controllers[$i]}':27017" }, ' >> /root/mongo_replica_setup.js
            else
                    echo -n '{ _id: '$i', host: "'${controllers[$i]}':27017" }' >> /root/mongo_replica_setup.js
            fi
    done
    echo ' ] }' >> /root/mongo_replica_setup.js
    echo 'rs.initiate(config)' >> /root/mongo_replica_setup.js
    # 配置mongodb
    mongo /root/mongo_replica_setup.js

    ### [controller01] 验证mongod集群配置正确
    echo "=== TRACE MESSAGE ===>>> " "请验证mongod集群配置是否正确，且当前节点是PRIMARY节点，然后按任意键继续 ...... ...... ...... [-]" | tee -a $log_file
    read answer

    ### [controller01] 新建mongodb数据库和用户，设置权限
    echo "=== TRACE MESSAGE ===>>> " "新建mongodb数据库和用户，设置权限" | tee -a $log_file
    # use double quota to enable eval to interpret shell variable
    mongo --host controller01 --eval "
      db = db.getSiblingDB('ceilometer');
      db.createUser({user: 'ceilometer',
      pwd: $ceilometer_db_password,
      roles: [ 'readWrite', 'dbAdmin' ]})" >> $log_file

    ### [controller01] 验证mongod集群配置正确
    echo "=== TRACE MESSAGE ===>>> " "请验证ceilometer用户是否可以访问ceilometer数据库，然后按任意键继续 ...... ...... ...... [-]" | tee -a $log_file
    read answer

    for c in ${controllers[@]};
    do
        ### [所有控制节点] 修改/etc/haproxy/haproxy.cfg文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/haproxy/haproxy.cfg文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen ceilometer_api_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:8777" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]};
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:8777 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done;
    done;

    ### [controller01]创建用户、服务实体、端点
    echo "=== TRACE MESSAGE ===>>> " "创建用户、服务实体、端点" | tee -a $log_file
    openstack user create --domain default --password $ceilometer_ks_password ceilometer >> $log_file
    openstack role add --project service --user ceilometer admin >> $log_file
    openstack service create --name ceilometer --description "Telemetry" metering >> $log_file
    openstack endpoint create --region RegionOne metering public http://$virtual_ip:8777 >> $log_file
    openstack endpoint create --region RegionOne metering internal http://$virtual_ip:8777 >> $log_file
    openstack endpoint create --region RegionOne metering admin http://$virtual_ip:8777 >> $log_file

    for c in ${controllers[@]};
    do
        ### [所有控制节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件" | tee -a $log_file
        ssh $c yum install -y openstack-ceilometer-api openstack-ceilometer-collector openstack-ceilometer-notification openstack-ceilometer-central python-ceilometerclient redis python-redis >> $log_file

        ### [所有控制节点] 配置redis
        echo "=== TRACE MESSAGE ===>>> " $c ": 配置redis" | tee -a $log_file
        ssh $c /bin/bash << EOF
            sed -i "s/\s*bind \(.*\)$/#bind \1/" /etc/redis.conf
EOF

        ### [所有控制节点]修改/etc/ceilometer/ceilometer.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/ceilometer/ceilometer.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            openstack-config --set /etc/ceilometer/ceilometer.conf database connection mongodb://ceilometer:$ceilometer_db_password@$mongodb_servers_list/ceilometer?replicaSet=ceilometer
            openstack-config --set /etc/ceilometer/ceilometer.conf database max_retries -1

            openstack-config --set /etc/ceilometer/ceilometer.conf DEFAULT rpc_backend rabbit
            openstack-config --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit rabbit_hosts $rabbit_hosts_list
            openstack-config --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit rabbit_ha_queues true
            openstack-config --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit rabbit_retry_interval 1
            openstack-config --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit rabbit_retry_backoff 2
            openstack-config --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit rabbit_max_retries 0
            openstack-config --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit rabbit_durable_queues true
            openstack-config --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit rabbit_userid $rabbitmq_username
            openstack-config --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit rabbit_password $rabbitmq_password

            openstack-config --set /etc/ceilometer/ceilometer.conf DEFAULT auth_strategy keystone
            openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken auth_uri http://$virtual_ip:5000
            openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken auth_url http://$virtual_ip:35357
            openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken memcached_servers $memcached_servers_list
            openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken auth_type password
            openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken project_domain_name default
            openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken user_domain_name default
            openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken project_name service
            openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken username ceilometer
            openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken password $ceilometer_ks_password

            openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials auth_type password
            openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials auth_url http://$virtual_ip:5000/v3
            openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials project_domain_name default
            openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials user_domain_name default
            openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials project_name service
            openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials username ceilometer
            openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials password $ceilometer_ks_password
            openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials interface internalURL
            openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials region_name RegionOne

            # keep last 5 days data only (value is in secs). Don't set to retain all data indefinetely.
            openstack-config --set  /etc/ceilometer/ceilometer.conf database metering_time_to_live 432000

            # Without the backend_url option being set only one instance of both the central and compute agent service is able to run and function correctly.
            openstack-config --set /etc/ceilometer/ceilometer.conf coordination backend_url 'redis://$redis_vip:6379'

            openstack-config --set  /etc/ceilometer/ceilometer.conf api host ${controller_mgmt_nic_map[$c]}

            openstack-config --set /etc/ceilometer/ceilometer.conf publisher telemetry_secret $telemetry_secret
EOF
    done;

    #
    # alarming服务
    #

    echo "=== TRACE MESSAGE ===>>> " "安装alarming服务..." | tee -a $log_file

    ### [controller01]创建数据库
    echo "=== TRACE MESSAGE ===>>> " "创建数据库" | tee -a $log_file
    mysql -uroot -e "CREATE DATABASE aodh;"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON aodh.* TO 'aodh'@'localhost' IDENTIFIED BY '$aodh_db_password';"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON aodh.* TO 'aodh'@'%' IDENTIFIED BY '$aodh_db_password';"
    mysql -uroot -e "FLUSH PRIVILEGES;"

    for c in ${controllers[@]};
    do
        ### [所有控制节点] 修改/etc/haproxy/haproxy.cfg文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/haproxy/haproxy.cfg文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen aodh_api_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:8042" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]};
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:8042 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done;
    done;

    ### [controller01]创建用户、服务实体、端点
    echo "=== TRACE MESSAGE ===>>> " "创建用户、服务实体、端点" | tee -a $log_file
    openstack user create --domain default --password $aodh_ks_password aodh >> $log_file
    openstack role add --project service --user aodh admin >> $log_file
    openstack service create --name aodh --description "Telemetry" alarming >> $log_file
    openstack endpoint create --region RegionOne alarming public http://$virtual_ip:8042 >> $log_file
    openstack endpoint create --region RegionOne alarming internal http://$virtual_ip:8042 >> $log_file
    openstack endpoint create --region RegionOne alarming admin http://$virtual_ip:8042 >> $log_file

    for c in ${controllers[@]};
    do
        ### [所有控制节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件" | tee -a $log_file
        ssh $c yum install -y openstack-aodh-api openstack-aodh-evaluator openstack-aodh-notifier openstack-aodh-listener openstack-aodh-expirer python-ceilometerclient >> $log_file

        ### [所有控制节点]修改/etc/aodh/aodh.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/aodh/aodh.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            openstack-config --set /etc/aodh/aodh.conf database connection mysql+pymysql://aodh:$aodh_db_password@$virtual_ip/aodh

            openstack-config --set /etc/aodh/aodh.conf DEFAULT rpc_backend rabbit
            openstack-config --set /etc/aodh/aodh.conf oslo_messaging_rabbit rabbit_hosts $rabbit_hosts_list
            openstack-config --set /etc/aodh/aodh.conf oslo_messaging_rabbit rabbit_ha_queues true
            openstack-config --set /etc/aodh/aodh.conf oslo_messaging_rabbit rabbit_retry_interval 1
            openstack-config --set /etc/aodh/aodh.conf oslo_messaging_rabbit rabbit_retry_backoff 2
            openstack-config --set /etc/aodh/aodh.conf oslo_messaging_rabbit rabbit_max_retries 0
            openstack-config --set /etc/aodh/aodh.conf oslo_messaging_rabbit rabbit_durable_queues true
            openstack-config --set /etc/aodh/aodh.conf oslo_messaging_rabbit rabbit_userid $rabbitmq_username
            openstack-config --set /etc/aodh/aodh.conf oslo_messaging_rabbit rabbit_password $rabbitmq_password

            openstack-config --set /etc/aodh/aodh.conf DEFAULT auth_strategy keystone
            openstack-config --set /etc/aodh/aodh.conf keystone_authtoken auth_uri http://$virtual_ip:5000
            openstack-config --set /etc/aodh/aodh.conf keystone_authtoken auth_url http://$virtual_ip:35357
            openstack-config --set /etc/aodh/aodh.conf keystone_authtoken memcached_servers $memcached_servers_list
            openstack-config --set /etc/aodh/aodh.conf keystone_authtoken auth_type password
            openstack-config --set /etc/aodh/aodh.conf keystone_authtoken project_domain_name default
            openstack-config --set /etc/aodh/aodh.conf keystone_authtoken user_domain_name default
            openstack-config --set /etc/aodh/aodh.conf keystone_authtoken project_name service
            openstack-config --set /etc/aodh/aodh.conf keystone_authtoken username aodh
            openstack-config --set /etc/aodh/aodh.conf keystone_authtoken password $aodh_ks_password

            openstack-config --set /etc/aodh/aodh.conf service_credentials auth_type password
            openstack-config --set /etc/aodh/aodh.conf service_credentials auth_url http://$virtual_ip:5000/v3
            openstack-config --set /etc/aodh/aodh.conf service_credentials project_domain_name default
            openstack-config --set /etc/aodh/aodh.conf service_credentials user_domain_name default
            openstack-config --set /etc/aodh/aodh.conf service_credentials project_name service
            openstack-config --set /etc/aodh/aodh.conf service_credentials username aodh
            openstack-config --set /etc/aodh/aodh.conf service_credentials password $aodh_ks_password
            openstack-config --set /etc/aodh/aodh.conf service_credentials interface internalURL
            openstack-config --set /etc/aodh/aodh.conf service_credentials region_name RegionOne

            openstack-config --set /etc/aodh/aodh.conf api host ${controller_mgmt_nic_map[$c]}
EOF
    done;

    ### [controller01]生成数据库
    echo "=== TRACE MESSAGE ===>>> " "生成数据库" | tee -a $log_file
    su -s /bin/sh -c "aodh-dbsync" aodh >> $log_file

    ### [controller01]添加pacemaker资源
    echo "=== TRACE MESSAGE ===>>> " "添加pacemaker资源" | tee -a $log_file
    pcs resource create redis redis wait_last_known_master=true --master meta notify=true ordered=true interleave=true
    pcs resource create redis-virtual-ip IPaddr2 ip=$redis_vip
    pcs resource create openstack-ceilometer-central systemd:openstack-ceilometer-central op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-ceilometer-collector systemd:openstack-ceilometer-collector op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-ceilometer-api systemd:openstack-ceilometer-api op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create delay Delay startdelay=10 --clone interleave=true
    pcs resource create openstack-aodh-evaluator systemd:openstack-aodh-evaluator op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-aodh-notifier systemd:openstack-aodh-notifier op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-aodh-api systemd:openstack-aodh-api op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-aodh-listener systemd:openstack-aodh-listener op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-ceilometer-notification systemd:openstack-ceilometer-notification op start timeout=120 stop timeout=300 --clone interleave=true

    pcs constraint order promote redis-master then start redis-virtual-ip
    pcs constraint order start redis-virtual-ip then openstack-ceilometer-central-clone kind=Optional
    pcs constraint order start mongod-clone then openstack-ceilometer-central-clone
    pcs constraint order start openstack-keystone-clone then openstack-ceilometer-central-clone
    pcs constraint order start openstack-ceilometer-central-clone then openstack-ceilometer-collector-clone
    pcs constraint order start openstack-ceilometer-collector-clone then openstack-ceilometer-api-clone
    pcs constraint order start openstack-ceilometer-api-clone then delay-clone
    pcs constraint order start delay-clone then openstack-aodh-evaluator-clone
    pcs constraint order start openstack-aodh-evaluator-clone then openstack-aodh-notifier-clone
    pcs constraint order start openstack-aodh-notifier-clone then openstack-aodh-api-clone
    pcs constraint order start openstack-aodh-api-clone then openstack-aodh-listener-clone
    pcs constraint order start openstack-aodh-api-clone then openstack-ceilometer-notification-clone

    pcs constraint colocation add redis-virtual-ip with master redis-master
    # pcs constraint colocation add openstack-ceilometer-api-clone with openstack-ceilometer-collector-clone
    # pcs constraint colocation add delay-clone with openstack-ceilometer-api-clone

    ### [controller01] 等待telemetry服务启动
    echo "=== TRACE MESSAGE ===>>> " "等待telemetry服务启动，确认服务在vip也开启监听，然后按任意键继续 ...... ...... ...... [-]" | tee -a $log_file
    read answer

    ### [controller01]测试metering服务
    echo "=== TRACE MESSAGE ===>>> " "测试metering服务" | tee -a $log_file
    ceilometer meter-list

    ### [controller01]测试alarming服务
    echo "=== TRACE MESSAGE ===>>> " "测试alarming服务" | tee -a $log_file
    ceilometer alarm-list
}

echo -n "confirm to install telemetry [y|n]"
read answer
if [ $answer == "y" ]; then
    install_telemetry
fi