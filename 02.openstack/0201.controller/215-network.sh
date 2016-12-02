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

function install_network() {
    ### [controller01]创建数据库
    echo "=== TRACE MESSAGE ===>>> " "创建数据库" | tee -a $log_file
    mysql -uroot -e "CREATE DATABASE neutron;"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '$neutron_db_password';"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '$neutron_db_password';"
    mysql -uroot -e "FLUSH PRIVILEGES;"

    for c in ${controllers[@]}
    do
        ### [所有控制节点] 修改/etc/haproxy/haproxy.cfg文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/haproxy/haproxy.cfg文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen neutron_api_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:9696" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  httpchk" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]}
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:9696 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done
    done

    ### [controller01]创建用户、服务实体、端点
    echo "=== TRACE MESSAGE ===>>> " "创建用户、服务实体、端点" | tee -a $log_file
    openstack user create --domain default --password $neutron_ks_password neutron >> $log_file
    openstack role add --project service --user neutron admin >> $log_file
    openstack service create --name neutron --description "OpenStack Networking" network >> $log_file
    openstack endpoint create --region RegionOne network public http://$virtual_ip:9696 >> $log_file
    openstack endpoint create --region RegionOne network internal http://$virtual_ip:9696 >> $log_file
    openstack endpoint create --region RegionOne network admin http://$virtual_ip:9696 >> $log_file

    for c in ${controllers[@]}
    do
        ### [所有控制节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件" | tee -a $log_file
        ssh $c yum install -y openstack-neutron openstack-neutron-ml2 >> $log_file

        ### [所有控制节点]修改/etc/neutron/neutron.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/neutron/neutron.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            openstack-config --set /etc/neutron/neutron.conf DEFAULT bind_host ${controller_mgmt_nic_map[$c]}

            openstack-config --set /etc/neutron/neutron.conf database connection mysql+pymysql://neutron:$neutron_db_password@$virtual_ip/neutron

            openstack-config --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
            openstack-config --set /etc/neutron/neutron.conf DEFAULT service_plugins router
            openstack-config --set /etc/neutron/neutron.conf DEFAULT allow_overlapping_ips True

            openstack-config --set /etc/neutron/neutron.conf DEFAULT rpc_backend rabbit
            openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_hosts $rabbit_hosts_list
            openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_ha_queues true
            openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_retry_interval 1
            openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_retry_backoff 2
            openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_max_retries 0
            openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_durable_queues true
            openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_userid $rabbitmq_username
            openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_password $rabbitmq_password

            openstack-config --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
            openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_uri http://$virtual_ip:5000
            openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_url http://$virtual_ip:35357
            openstack-config --set /etc/neutron/neutron.conf keystone_authtoken memcached_servers $memcached_servers_list
            openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_type password
            openstack-config --set /etc/neutron/neutron.conf keystone_authtoken project_domain_name default
            openstack-config --set /etc/neutron/neutron.conf keystone_authtoken user_domain_name default
            openstack-config --set /etc/neutron/neutron.conf keystone_authtoken project_name service
            openstack-config --set /etc/neutron/neutron.conf keystone_authtoken username neutron
            openstack-config --set /etc/neutron/neutron.conf keystone_authtoken password $neutron_ks_password

            openstack-config --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_status_changes True
            openstack-config --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_data_changes True
            openstack-config --set /etc/neutron/neutron.conf nova auth_url http://$virtual_ip:35357
            openstack-config --set /etc/neutron/neutron.conf nova auth_type password
            openstack-config --set /etc/neutron/neutron.conf nova project_domain_name default
            openstack-config --set /etc/neutron/neutron.conf nova user_domain_name default
            openstack-config --set /etc/neutron/neutron.conf nova region_name RegionOne
            openstack-config --set /etc/neutron/neutron.conf nova project_name service
            openstack-config --set /etc/neutron/neutron.conf nova username nova
            openstack-config --set /etc/neutron/neutron.conf nova password $nova_ks_password

            openstack-config --set /etc/neutron/neutron.conf oslo_concurrency lock_path /var/lib/neutron/tmp
EOF

        ### [所有控制节点]修改/etc/neutron/neutron.conf文件(L3 agent HA, DHCP agent HA)
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/neutron/neutron.conf文件(L3 agent HA, DHCP agent HA)" | tee -a $log_file
        ssh $c /bin/bash << EOF
            openstack-config --set /etc/neutron/neutron.conf DEFAULT l3_ha True
            openstack-config --set /etc/neutron/neutron.conf DEFAULT allow_automatic_l3agent_failover True
            openstack-config --set /etc/neutron/neutron.conf DEFAULT max_l3_agents_per_router 3
            openstack-config --set /etc/neutron/neutron.conf DEFAULT min_l3_agents_per_router 2

            openstack-config --set /etc/neutron/neutron.conf DEFAULT dhcp_agents_per_network 3     
EOF

        ### [所有控制节点]修改/etc/neutron/plugins/ml2/ml2_conf.ini文件 
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/neutron/plugins/ml2/ml2_conf.ini文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 type_drivers flat,vlan,vxlan,gre
            openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 tenant_network_types vxlan
            openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers openvswitch,l2population
            openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 extension_drivers port_security

            openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat flat_networks external

            openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan vni_ranges 1:1000

            openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup enable_security_group True
            openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup enable_ipset True
            openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup firewall_driver iptables_hybrid
EOF

        ### [所有控制节点]修改/etc/nova/nova.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/nova/nova.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            openstack-config --set /etc/nova/nova.conf neutron url http://$virtual_ip:9696
            openstack-config --set /etc/nova/nova.conf neutron auth_url http://$virtual_ip:35357
            openstack-config --set /etc/nova/nova.conf neutron auth_type password
            openstack-config --set /etc/nova/nova.conf neutron project_domain_name default
            openstack-config --set /etc/nova/nova.conf neutron user_domain_name default
            openstack-config --set /etc/nova/nova.conf neutron region_name RegionOne
            openstack-config --set /etc/nova/nova.conf neutron project_name service
            openstack-config --set /etc/nova/nova.conf neutron username neutron
            openstack-config --set /etc/nova/nova.conf neutron password $neutron_ks_password

            openstack-config --set /etc/nova/nova.conf neutron service_metadata_proxy True
            openstack-config --set /etc/nova/nova.conf neutron metadata_proxy_shared_secret $metadata_secret_key
EOF
    done

    for c in ${controllers[@]}
    do
        ### [所有控制节点] 创建ML2配置文件软连接
        echo "=== TRACE MESSAGE ===>>> " $c ": 创建ML2配置文件软连接" | tee -a $log_file
        ssh $c ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
    done

    ### [controller01]生成数据库
    echo "=== TRACE MESSAGE ===>>> " "生成数据库" | tee -a $log_file
    su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron >> $log_file

    ### [controller01]添加pacemaker资源
    echo "=== TRACE MESSAGE ===>>> " "添加pacemaker资源" | tee -a $log_file
    pcs resource create neutron-server systemd:neutron-server op start timeout=120 stop timeout=300 --clone interleave=true
    
    pcs constraint order start openstack-keystone-clone then neutron-server-clone

    ### [controller01] 等待neutron服务启动
    echo "=== TRACE MESSAGE ===>>> " "等待neutron服务启动，确认服务在vip也开启监听，然后按任意键继续 ...... ...... ...... [-]" | tee -a $log_file
    read answer

    ### [controller01]测试neutron服务
    echo "=== TRACE MESSAGE ===>>> " "测试neutron服务" | tee -a $log_file
    neutron ext-list
}

echo -n "confirm to install network [y|n]"
read answer
if [ $answer == "y" ]; then
    install_network
fi