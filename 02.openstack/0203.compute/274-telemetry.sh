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
    for h in ${hypervisors[@]};
    do
        ### [所有计算节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $h ": 安装软件" | tee -a $log_file
        ssh $h yum install -y openstack-ceilometer-compute python-ceilometerclient python-pecan >> $log_file

        ### [所有计算节点]修改/etc/ceilometer/ceilometer.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $h ": 修改/etc/ceilometer/ceilometer.conf文件" | tee -a $log_file
        ssh $h /bin/bash << EOF
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
EOF

        ### [所有计算节点]修改/etc/nova/nova.conf文件，nova使用ceilometer服务
        echo "=== TRACE MESSAGE ===>>> " $h ": 修改/etc/nova/nova.conf文件" | tee -a $log_file
        ssh $h /bin/bash << EOF
            openstack-config --set /etc/nova/nova.conf DEFAULT instance_usage_audit True
            openstack-config --set /etc/nova/nova.conf DEFAULT instance_usage_audit_period hour
            openstack-config --set /etc/nova/nova.conf DEFAULT notify_on_state_change vm_and_task_state
            openstack-config --set /etc/nova/nova.conf DEFAULT notification_driver messagingv2
EOF

        ### [所有计算节点]配置服务
        echo "=== TRACE MESSAGE ===>>> " $h ": 配置服务" | tee -a $log_file
        ssh $h /bin/bash << EOF
            systemctl enable openstack-ceilometer-compute.service >> $log_file
            systemctl start openstack-ceilometer-compute.service
            systemctl restart openstack-nova-compute.service
EOF
    done;
}

echo -n "confirm to install telemetry [y|n]"
read answer
if [ $answer == "y" ]; then
    install_telemetry
fi