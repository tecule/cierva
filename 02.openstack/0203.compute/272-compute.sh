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
    for h in ${hypervisors[@]};
    do
        ### [所有计算节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $h ": 安装软件" | tee -a $log_file
        ssh $h yum install -y openstack-nova-compute >> $log_file

        ### [所有计算节点]修改/etc/nova/nova.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $h ": 修改/etc/nova/nova.conf文件" | tee -a $log_file
        ssh $h /bin/bash << EOF
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

            openstack-config --set /etc/nova/nova.conf DEFAULT my_ip ${hypervisor_mgmt_nic_map[$h]}

            openstack-config --set /etc/nova/nova.conf DEFAULT use_neutron True
            openstack-config --set /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver

            openstack-config --set /etc/nova/nova.conf vnc enabled True
            openstack-config --set /etc/nova/nova.conf vnc vncserver_listen 0.0.0.0
            openstack-config --set /etc/nova/nova.conf vnc vncserver_proxyclient_address ${hypervisor_mgmt_nic_map[$h]}
            openstack-config --set /etc/nova/nova.conf vnc novncproxy_base_url http://$virtual_ip:6080/vnc_auto.html

            openstack-config --set /etc/nova/nova.conf glance api_servers http://$virtual_ip:9292
EOF

        ### [所有计算节点]修改/etc/libvirt/libvirtd.conf和/etc/sysconfig/libvirtd文件，打开虚拟机迁移的监听端口
        echo "=== TRACE MESSAGE ===>>> " $h ": 修改/etc/libvirt/libvirtd.conf和/etc/sysconfig/libvirtd文件" | tee -a $log_file
        ssh $h /bin/bash << EOF
            sed -i \
                -e 's/^#listen_tls = .*/listen_tls = 0/' \
                -e 's/^#listen_tcp = .*/listen_tcp = 1/' \
                -e 's/^#auth_tcp = .*/auth_tcp = "none"/' \
                /etc/libvirt/libvirtd.conf

            sed -i \
                -e 's/^#LIBVIRTD_ARGS=.*/LIBVIRTD_ARGS="--listen"/g' \
                /etc/sysconfig/libvirtd
EOF

        ### [所有计算节点]配置服务
        echo "=== TRACE MESSAGE ===>>> " $h ": 配置服务" | tee -a $log_file
        ssh $h /bin/bash << EOF
            systemctl enable libvirtd.service openstack-nova-compute.service >> $log_file
            systemctl start libvirtd.service openstack-nova-compute.service
EOF
    done;
}

echo -n "confirm to install compute [y|n]"
read answer
if [ $answer == "y" ]; then
    install_compute
fi