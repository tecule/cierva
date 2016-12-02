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
    for h in ${hypervisors[@]};
    do
        ### [所有计算节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $h ": 安装软件" | tee -a $log_file
        ssh $h yum install -y openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch >> $log_file

        ### [所有计算节点]修改/etc/neutron/neutron.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $h ": 修改/etc/neutron/neutron.conf文件" | tee -a $log_file
        ssh $h /bin/bash << EOF
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

            openstack-config --set /etc/neutron/neutron.conf oslo_concurrency lock_path /var/lib/neutron/tmp
EOF

        ### [所有计算节点]修改/etc/neutron/plugins/ml2/openvswitch_agent.ini文件 
        echo "=== TRACE MESSAGE ===>>> " $h ": 修改/etc/neutron/plugins/ml2/openvswitch_agent.ini文件" | tee -a $log_file
        ssh $h /bin/bash << EOF
            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup enable_security_group True
            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup enable_ipset True
            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup firewall_driver iptables_hybrid

            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs local_ip ${hypervisor_tunnel_nic_map[$h]}

            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini agent tunnel_types vxlan
            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini agent l2_population False
EOF

        ### [所有计算节点]配置Open vSwitch (OVS) 服务
        echo "=== TRACE MESSAGE ===>>> " $h ": 配置Open vSwitch (OVS) 服务" | tee -a $log_file
        ssh $h /bin/bash << EOF
            systemctl enable openvswitch.service >> $log_file
            systemctl start openvswitch.service
EOF

        ### [所有计算节点]修改/etc/nova/nova.conf文件，配置nova和neutron集成
        echo "=== TRACE MESSAGE ===>>> " $h ": 修改/etc/nova/nova.conf文件" | tee -a $log_file
        ssh $h /bin/bash << EOF
            openstack-config --set /etc/nova/nova.conf neutron url http://$virtual_ip:9696
            openstack-config --set /etc/nova/nova.conf neutron auth_url http://$virtual_ip:35357
            openstack-config --set /etc/nova/nova.conf neutron auth_type password
            openstack-config --set /etc/nova/nova.conf neutron project_domain_name default
            openstack-config --set /etc/nova/nova.conf neutron user_domain_name default
            openstack-config --set /etc/nova/nova.conf neutron region_name RegionOne
            openstack-config --set /etc/nova/nova.conf neutron project_name service
            openstack-config --set /etc/nova/nova.conf neutron username neutron
            openstack-config --set /etc/nova/nova.conf neutron password $neutron_ks_password
EOF

        ### [所有控制节点] 创建ML2配置文件软连接
        echo "=== TRACE MESSAGE ===>>> " $h ": 创建ML2配置文件软连接" | tee -a $log_file
        ssh $h ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini

        ### [所有计算节点]配置服务
        echo "=== TRACE MESSAGE ===>>> " $h ": 配置服务" | tee -a $log_file
        ssh $h /bin/bash << EOF
            systemctl restart openstack-nova-compute.service
            systemctl enable neutron-openvswitch-agent.service >> $log_file
            systemctl start neutron-openvswitch-agent.service
EOF
    done;
}

echo -n "confirm to install network [y|n]"
read answer
if [ $answer == "y" ]; then
    install_network
fi