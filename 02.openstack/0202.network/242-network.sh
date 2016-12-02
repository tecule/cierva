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
    for n in ${networks[@]};
    do
        ### [所有网络节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $n ": 安装软件" | tee -a $log_file
        ssh $n yum install -y openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch >> $log_file

        ### [所有网络节点]修改/etc/neutron/neutron.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $n ": 修改/etc/neutron/neutron.conf文件" | tee -a $log_file
        ssh $n /bin/bash << EOF
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

            openstack-config --set /etc/neutron/neutron.conf oslo_concurrency lock_path /var/lib/neutron/tmp
EOF

        ### [所有网络节点]修改/etc/neutron/plugins/ml2/ml2_conf.ini文件 
        echo "=== TRACE MESSAGE ===>>> " $n ": 修改/etc/neutron/plugins/ml2/ml2_conf.ini文件" | tee -a $log_file
        ssh $n /bin/bash << EOF
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

        ### [所有网络节点]修改/etc/neutron/plugins/ml2/openvswitch_agent.ini文件 
        echo "=== TRACE MESSAGE ===>>> " $n ": 修改/etc/neutron/plugins/ml2/openvswitch_agent.ini文件" | tee -a $log_file
        ssh $n /bin/bash << EOF
            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup enable_security_group True
            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup enable_ipset True
            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup firewall_driver iptables_hybrid

            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs local_ip ${network_tunnel_nic_map[$n]}
            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings external:br-ex

            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini agent tunnel_types vxlan
            openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini agent l2_population True
EOF

        ### [所有网络节点]修改/etc/neutron/l3_agent.ini文件 
        echo "=== TRACE MESSAGE ===>>> " $n ": 修改/etc/neutron/l3_agent.ini文件" | tee -a $log_file
        ssh $n /bin/bash << EOF
            openstack-config --set /etc/neutron/l3_agent.ini DEFAULT interface_driver neutron.agent.linux.interface.OVSInterfaceDriver
            openstack-config --set /etc/neutron/l3_agent.ini DEFAULT external_network_bridge
EOF

        ### [所有网络节点]修改/etc/neutron/dhcp_agent.ini文件 
        echo "=== TRACE MESSAGE ===>>> " $n ": 修改/etc/neutron/dhcp_agent.ini文件" | tee -a $log_file
        ssh $n /bin/bash << EOF
            openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT interface_driver neutron.agent.linux.interface.OVSInterfaceDriver
            openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
            openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata True
EOF

        ### [所有网络节点]修改/etc/neutron/metadata_agent.ini文件 
        echo "=== TRACE MESSAGE ===>>> " $n ": 修改/etc/neutron/metadata_agent.ini文件" | tee -a $log_file
        ssh $n /bin/bash << EOF
            openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT nova_metadata_ip $virtual_ip
            openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT metadata_proxy_shared_secret $metadata_secret_key
EOF
    done;

    for n in ${networks[@]};
    do
        ### [所有网络节点] 配置Open vSwitch (OVS) 服务，创建网桥和端口
        echo "=== TRACE MESSAGE ===>>> " $n ": 配置Open vSwitch (OVS)服务" | tee -a $log_file
        ssh $n /bin/bash << EOF
            systemctl enable openvswitch.service >> $log_file
            systemctl start openvswitch.service

            ### 添加网桥和端口后网络中断，因此该操作由安装人员手工执行
            # ovs-vsctl add-br br-ex
            # ovs-vsctl add-port br-ex $management_nic
            #        
EOF
    done

    for n in ${networks[@]};
    do
        ### [所有网络节点] 创建ML2配置文件软连接
        echo "=== TRACE MESSAGE ===>>> " $n ": 创建ML2配置文件软连接" | tee -a $log_file
        ssh $n ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
    done

    ### [network01]添加pacemaker资源
    echo "=== TRACE MESSAGE ===>>> " $network_0 "添加pacemaker资源" | tee -a $log_file    
    ssh $network_0 /bin/bash << EOF
        pcs resource create neutron-scale ocf:neutron:NeutronScale --clone globally-unique=true clone-max=3 interleave=true
        pcs resource create neutron-ovs-cleanup ocf:neutron:OVSCleanup --clone interleave=true
        pcs resource create neutron-netns-cleanup ocf:neutron:NetnsCleanup --clone interleave=true
        pcs resource create neutron-openvswitch-agent systemd:neutron-openvswitch-agent op start timeout=120 stop timeout=300 --clone interleave=true
        pcs resource create neutron-dhcp-agent systemd:neutron-dhcp-agent op start timeout=120 stop timeout=300 --clone interleave=true
        pcs resource create neutron-l3-agent systemd:neutron-l3-agent op start timeout=120 stop timeout=300 --clone interleave=true
        pcs resource create neutron-metadata-agent systemd:neutron-metadata-agent op start timeout=120 stop timeout=300 --clone interleave=true
        
        pcs constraint order start neutron-scale-clone then neutron-ovs-cleanup-clone
        pcs constraint order start neutron-ovs-cleanup-clone then neutron-netns-cleanup-clone
        pcs constraint order start neutron-netns-cleanup-clone then neutron-openvswitch-agent-clone
        pcs constraint order start neutron-openvswitch-agent-clone then neutron-dhcp-agent-clone
        pcs constraint order start neutron-dhcp-agent-clone then neutron-l3-agent-clone
        pcs constraint order start neutron-l3-agent-clone then neutron-metadata-agent-clone
        
        # pcs constraint colocation add neutron-ovs-cleanup-clone with neutron-scale-clone
        # pcs constraint colocation add neutron-netns-cleanup-clone with neutron-ovs-cleanup-clone
        # pcs constraint colocation add neutron-openvswitch-agent-clone with neutron-netns-cleanup-clone
        # pcs constraint colocation add neutron-dhcp-agent-clone with neutron-openvswitch-agent-clone
        # pcs constraint colocation add neutron-l3-agent-clone with neutron-dhcp-agent-clone
        # pcs constraint colocation add neutron-metadata-agent-clone with neutron-l3-agent-clone
EOF

    ### [controller01] 服务配置尚未完成
    echo "=== TRACE MESSAGE ===>>> " "---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ----" | tee -a $log_file
    echo "=== TRACE MESSAGE ===>>> " "服务配置尚未完成，请手工添加网桥和端口，修改br-ex网桥和mgmt nic的网卡配置文件，并测试network服务" | tee -a $log_file
    echo "=== TRACE MESSAGE ===>>> " "---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ----" | tee -a $log_file
}

echo -n "confirm to install network [y|n]"
read answer
if [ $answer == "y" ]; then
    install_network
fi