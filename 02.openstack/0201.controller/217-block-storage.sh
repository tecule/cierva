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

function install_block_storage() {
    ### [controller01]创建数据库
    echo "=== TRACE MESSAGE ===>>> " "创建数据库" | tee -a $log_file
    mysql -uroot -e "CREATE DATABASE cinder;"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '$cinder_db_password';"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '$cinder_db_password';"
    mysql -uroot -e "FLUSH PRIVILEGES;"

    for c in ${controllers[@]};
    do
        ### [所有控制节点] 修改/etc/haproxy/haproxy.cfg文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/haproxy/haproxy.cfg文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen cinder_api_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:8776" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  httpchk" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]};
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:8776 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done;
    done;

    ### [controller01]创建用户、服务实体、端点
    echo "=== TRACE MESSAGE ===>>> " "创建用户、服务实体、端点" | tee -a $log_file
    openstack user create --domain default --password $cinder_ks_password cinder >> $log_file
    openstack role add --project service --user cinder admin >> $log_file
    openstack service create --name cinder --description "OpenStack Block Storage" volume >> $log_file
    openstack service create --name cinderv2 --description "OpenStack Block Storage" volumev2 >> $log_file
    openstack endpoint create --region RegionOne volume public http://$virtual_ip:8776/v1/%\(tenant_id\)s >> $log_file
    openstack endpoint create --region RegionOne volume internal http://$virtual_ip:8776/v1/%\(tenant_id\)s >> $log_file
    openstack endpoint create --region RegionOne volume admin http://$virtual_ip:8776/v1/%\(tenant_id\)s >> $log_file
    openstack endpoint create --region RegionOne volumev2 public http://$virtual_ip:8776/v2/%\(tenant_id\)s >> $log_file
    openstack endpoint create --region RegionOne volumev2 internal http://$virtual_ip:8776/v2/%\(tenant_id\)s >> $log_file
    openstack endpoint create --region RegionOne volumev2 admin http://$virtual_ip:8776/v2/%\(tenant_id\)s >> $log_file

    # treat variable as an integer, arithmetic evaluation can be performed
    declare -i cinder_host_suffix=0
    for c in ${controllers[@]};
    do
        cinder_host_suffix=$cinder_host_suffix+1
        cinder_host="cinder-cluster-"$cinder_host_suffix

        ### [所有控制节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件" | tee -a $log_file
        ssh $c yum install -y openstack-cinder >> $log_file

        ### [所有控制节点]修改/etc/cinder/cinder.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/cinder/cinder.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            openstack-config --set /etc/cinder/cinder.conf database connection mysql+pymysql://cinder:$cinder_db_password@$virtual_ip/cinder
            openstack-config --set /etc/cinder/cinder.conf database max_retries -1

            openstack-config --set /etc/cinder/cinder.conf DEFAULT rpc_backend rabbit
            openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_hosts $rabbit_hosts_list
            openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_ha_queues true
            openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_retry_interval 1
            openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_retry_backoff 2
            openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_max_retries 0
            openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_durable_queues true
            openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_userid $rabbitmq_username
            openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_password $rabbitmq_password

            openstack-config --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
            openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_uri http://$virtual_ip:5000
            openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_url http://$virtual_ip:35357
            openstack-config --set /etc/cinder/cinder.conf keystone_authtoken memcached_servers $memcached_servers_list
            openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_type password
            openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_domain_name default
            openstack-config --set /etc/cinder/cinder.conf keystone_authtoken user_domain_name default
            openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_name service
            openstack-config --set /etc/cinder/cinder.conf keystone_authtoken username cinder
            openstack-config --set /etc/cinder/cinder.conf keystone_authtoken password $cinder_ks_password

            openstack-config --set /etc/cinder/cinder.conf DEFAULT my_ip ${controller_mgmt_nic_map[$c]}

            openstack-config --set /etc/cinder/cinder.conf oslo_concurrency lock_path /var/lib/cinder/tmp

            # see http://docs.openstack.org/ha-guide/storage-ha-block.html
            # Its the name which we should advertise ourselves as and for A/P it should be the same everywhere ???
            openstack-config --set /etc/cinder/cinder.conf DEFAULT host $cinder_host
            # Listen on the Block Storage VIP ???
            openstack-config --set /etc/cinder/cinder.conf DEFAULT osapi_volume_listen ${controller_mgmt_nic_map[$c]}
            openstack-config --set /etc/cinder/cinder.conf DEFAULT control_exchange cinder
EOF

        ### [所有控制节点] 修改/etc/nova/nova.conf，允许Compute服务使用块存储
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/nova/nova.conf" | tee -a $log_file
        ssh $c openstack-config --set /etc/nova/nova.conf cinder os_region_name RegionOne
    done;

    ### [controller01]生成数据库
    echo "=== TRACE MESSAGE ===>>> " "生成数据库" | tee -a $log_file
    su -s /bin/sh -c "cinder-manage db sync" cinder >> $log_file

    ### [controller01]添加pacemaker资源
    echo "=== TRACE MESSAGE ===>>> " "添加pacemaker资源" | tee -a $log_file
    pcs resource create openstack-cinder-api systemd:openstack-cinder-api op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-cinder-scheduler systemd:openstack-cinder-scheduler op start timeout=120 stop timeout=300 --clone interleave=true
    # Volume must be A/P for now. See https://bugzilla.redhat.com/show_bug.cgi?id=1193229
    pcs resource create openstack-cinder-volume systemd:openstack-cinder-volume op start timeout=120 stop timeout=300

    pcs constraint order start openstack-keystone-clone then openstack-cinder-api-clone
    pcs constraint order start openstack-cinder-api-clone then openstack-cinder-scheduler-clone
    pcs constraint order start openstack-cinder-scheduler-clone then openstack-cinder-volume

    # pcs constraint colocation add openstack-cinder-scheduler-clone with openstack-cinder-api-clone
    # pcs constraint colocation add openstack-cinder-volume with openstack-cinder-scheduler-clone

    ### [controller01] 等待block storage服务启动
    echo "=== TRACE MESSAGE ===>>> " "等待block storage服务启动，确认服务在vip也开启监听，然后按任意键继续 ...... ...... ...... [-]" | tee -a $log_file
    read answer

    ### [controller01]测试block storage服务
    echo "=== TRACE MESSAGE ===>>> " "测试block storage服务" | tee -a $log_file
    cinder list
}

echo -n "confirm to install block storage [y|n]"
read answer
if [ $answer == "y" ]; then
    install_block_storage
fi