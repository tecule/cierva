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

function install_compute() {
    ### [controller01]创建数据库
    echo "=== TRACE MESSAGE ===>>> " "创建数据库" | tee -a $log_file
    mysql -uroot -e "CREATE DATABASE nova;"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '$nova_db_password';"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '$nova_db_password';"
    mysql -uroot -e "FLUSH PRIVILEGES;"

    mysql -uroot -e "CREATE DATABASE nova_api;"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost' IDENTIFIED BY '$nova_db_password';"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%' IDENTIFIED BY '$nova_db_password';"
    mysql -uroot -e "FLUSH PRIVILEGES;"

    for c in ${controllers[@]};
    do
        ### [所有控制节点] 修改/etc/haproxy/haproxy.cfg文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/haproxy/haproxy.cfg文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen nova_compute_api_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:8774" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  httpchk" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]};
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:8774 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done;

        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen nova_metadata_api_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:8775" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]};
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:8775 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done;

        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen nova_vncproxy_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:6080" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]};
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:6080 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done;
    done;

    ### [controller01]创建用户、服务实体、端点
    echo "=== TRACE MESSAGE ===>>> " "创建用户、服务实体、端点" | tee -a $log_file
    openstack user create --domain default --password $nova_ks_password nova >> $log_file
    openstack role add --project service --user nova admin >> $log_file
    openstack service create --name nova --description "OpenStack Compute" compute >> $log_file
    openstack endpoint create --region RegionOne compute public http://$virtual_ip:8774/v2.1/%\(tenant_id\)s >> $log_file
    openstack endpoint create --region RegionOne compute internal http://$virtual_ip:8774/v2.1/%\(tenant_id\)s >> $log_file
    openstack endpoint create --region RegionOne compute admin http://$virtual_ip:8774/v2.1/%\(tenant_id\)s >> $log_file

    for c in ${controllers[@]};
    do
        ### [所有控制节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件" | tee -a $log_file
        ssh $c yum install -y openstack-nova-api openstack-nova-conductor openstack-nova-console openstack-nova-novncproxy openstack-nova-scheduler >> $log_file

        ### [所有控制节点]修改/etc/nova/nova.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/nova/nova.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            openstack-config --set /etc/nova/nova.conf DEFAULT enabled_apis osapi_compute,metadata

            openstack-config --set /etc/nova/nova.conf api_database connection mysql+pymysql://nova:$nova_db_password@$virtual_ip/nova_api
            openstack-config --set /etc/nova/nova.conf database connection mysql+pymysql://nova:$nova_db_password@$virtual_ip/nova

            openstack-config --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit
            openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_hosts $rabbit_hosts_list
            openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_ha_queues true
            openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_retry_interval 1
            openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_retry_backoff 2
            openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_max_retries 0
            openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_durable_queues true
            openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_userid $rabbitmq_username
            openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_password $rabbitmq_password

            openstack-config --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
            openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_uri http://$virtual_ip:5000
            openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_url http://$virtual_ip:35357
            openstack-config --set /etc/nova/nova.conf keystone_authtoken memcached_servers $memcached_servers_list
            openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_type password
            openstack-config --set /etc/nova/nova.conf keystone_authtoken project_domain_name default
            openstack-config --set /etc/nova/nova.conf keystone_authtoken user_domain_name default
            openstack-config --set /etc/nova/nova.conf keystone_authtoken project_name service
            openstack-config --set /etc/nova/nova.conf keystone_authtoken username nova
            openstack-config --set /etc/nova/nova.conf keystone_authtoken password $nova_ks_password

            openstack-config --set /etc/nova/nova.conf DEFAULT my_ip ${controller_mgmt_nic_map[$c]}

            openstack-config --set /etc/nova/nova.conf DEFAULT use_neutron True
            openstack-config --set /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver

            openstack-config --set /etc/nova/nova.conf vnc vncserver_listen ${controller_mgmt_nic_map[$c]}
            openstack-config --set /etc/nova/nova.conf vnc vncserver_proxyclient_address ${controller_mgmt_nic_map[$c]}
            openstack-config --set /etc/nova/nova.conf vnc novncproxy_host ${controller_mgmt_nic_map[$c]}

            openstack-config --set /etc/nova/nova.conf glance api_servers http://$virtual_ip:9292

            openstack-config --set /etc/nova/nova.conf oslo_concurrency lock_path /var/lib/nova/tmp

            openstack-config --set /etc/nova/nova.conf DEFAULT osapi_compute_listen ${controller_mgmt_nic_map[$c]}
            openstack-config --set /etc/nova/nova.conf DEFAULT metadata_listen ${controller_mgmt_nic_map[$c]}

            # for consoleauth
            openstack-config --set /etc/nova/nova.conf DEFAULT memcached_servers $memcached_servers_list
EOF
    done;

    ### [controller01]生成数据库
    echo "=== TRACE MESSAGE ===>>> " "生成数据库" | tee -a $log_file
    su -s /bin/sh -c "nova-manage api_db sync" nova >> $log_file
    su -s /bin/sh -c "nova-manage db sync" nova >> $log_file

    ### [controller01]添加pacemaker资源
    echo "=== TRACE MESSAGE ===>>> " "添加pacemaker资源" | tee -a $log_file
    pcs resource create openstack-nova-consoleauth systemd:openstack-nova-consoleauth op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-nova-novncproxy systemd:openstack-nova-novncproxy op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-nova-api systemd:openstack-nova-api op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-nova-scheduler systemd:openstack-nova-scheduler op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-nova-conductor systemd:openstack-nova-conductor op start timeout=120 stop timeout=300 --clone interleave=true
    
    pcs constraint order start openstack-keystone-clone then openstack-nova-consoleauth-clone
    pcs constraint order start openstack-nova-consoleauth-clone then openstack-nova-novncproxy-clone
    pcs constraint order start openstack-nova-novncproxy-clone then openstack-nova-api-clone
    pcs constraint order start openstack-nova-api-clone then openstack-nova-scheduler-clone
    pcs constraint order start openstack-nova-scheduler-clone then openstack-nova-conductor-clone
    
    # pcs constraint colocation add openstack-nova-novncproxy-clone with openstack-nova-consoleauth-clone
    # pcs constraint colocation add openstack-nova-api-clone with openstack-nova-novncproxy-clone
    # pcs constraint colocation add openstack-nova-scheduler-clone with openstack-nova-api-clone
    # pcs constraint colocation add openstack-nova-conductor-clone with openstack-nova-scheduler-clone

    ### [controller01] 等待compute服务启动
    echo "=== TRACE MESSAGE ===>>> " "等待compute服务启动，确认服务在vip也开启监听，然后按任意键继续 ...... ...... ...... [-]" | tee -a $log_file
    read answer

    ### [controller01]测试compute服务
    echo "=== TRACE MESSAGE ===>>> " "测试compute服务" | tee -a $log_file
    nova service-list
}

echo -n "confirm to install compute [y|n]"
read answer
if [ $answer == "y" ]; then
    install_compute
fi