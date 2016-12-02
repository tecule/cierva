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

function install_image() {
    ### [controller01]创建数据库
    echo "=== TRACE MESSAGE ===>>> " "创建数据库" | tee -a $log_file
    mysql -uroot -e "CREATE DATABASE glance;"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '$glance_db_password';"
    mysql -uroot -e "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '$glance_db_password';"
    mysql -uroot -e "FLUSH PRIVILEGES;"

    for c in ${controllers[@]};
    do
        ### [所有控制节点] 修改/etc/haproxy/haproxy.cfg文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/haproxy/haproxy.cfg文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen glance_api_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:9292" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  httpchk" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]};
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:9292 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done;

        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen glance_registry_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:9191" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]};
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:9191 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done;
    done;

    ### [controller01]创建用户、服务实体、端点
    echo "=== TRACE MESSAGE ===>>> " "创建用户、服务实体、端点" | tee -a $log_file
    openstack user create --domain default --password $glance_ks_password glance >> $log_file
    openstack role add --project service --user glance admin >> $log_file
    openstack service create --name glance --description "OpenStack Image" image >> $log_file
    openstack endpoint create --region RegionOne image public http://$virtual_ip:9292 >> $log_file
    openstack endpoint create --region RegionOne image internal http://$virtual_ip:9292 >> $log_file
    openstack endpoint create --region RegionOne image admin http://$virtual_ip:9292 >> $log_file

    for c in ${controllers[@]};
    do
        ### [所有控制节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件" | tee -a $log_file
        ssh $c yum install -y openstack-glance >> $log_file

        ### [所有控制节点]修改/etc/glance/glance-api.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/glance/glance-api.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            openstack-config --set /etc/glance/glance-api.conf database connection mysql+pymysql://glance:$glance_db_password@$virtual_ip/glance

            openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_uri http://$virtual_ip:5000
            openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_url http://$virtual_ip:35357
            openstack-config --set /etc/glance/glance-api.conf keystone_authtoken memcached_servers $memcached_servers_list
            openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_type password
            openstack-config --set /etc/glance/glance-api.conf keystone_authtoken project_domain_name default
            openstack-config --set /etc/glance/glance-api.conf keystone_authtoken user_domain_name default
            openstack-config --set /etc/glance/glance-api.conf keystone_authtoken project_name service
            openstack-config --set /etc/glance/glance-api.conf keystone_authtoken username glance
            openstack-config --set /etc/glance/glance-api.conf keystone_authtoken password $glance_ks_password

            openstack-config --set /etc/glance/glance-api.conf paste_deploy flavor keystone

            openstack-config --set /etc/glance/glance-api.conf glance_store stores file,http
            openstack-config --set /etc/glance/glance-api.conf glance_store default_store file
            openstack-config --set /etc/glance/glance-api.conf glance_store filesystem_store_datadir /var/lib/glance/images/

            openstack-config --set /etc/glance/glance-api.conf DEFAULT registry_host $virtual_ip
            openstack-config --set /etc/glance/glance-api.conf DEFAULT bind_host ${controller_mgmt_nic_map[$c]}
EOF

        ### [所有控制节点]修改/etc/glance/glance-registry.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/glance/glance-registry.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            openstack-config --set /etc/glance/glance-registry.conf database connection mysql+pymysql://glance:$glance_db_password@$virtual_ip/glance

            openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_uri http://$virtual_ip:5000
            openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_url http://$virtual_ip:35357
            openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken memcached_servers $memcached_servers_list
            openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_type password
            openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken project_domain_name default
            openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken user_domain_name default
            openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken project_name service
            openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken username glance
            openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken password $glance_ks_password

            openstack-config --set /etc/glance/glance-registry.conf paste_deploy flavor keystone

            openstack-config --set /etc/glance/glance-registry.conf DEFAULT registry_host $virtual_ip
            openstack-config --set /etc/glance/glance-registry.conf DEFAULT bind_host ${controller_mgmt_nic_map[$c]}
EOF
    done;

    ### [controller01]生成数据库
    echo "=== TRACE MESSAGE ===>>> " "生成数据库" | tee -a $log_file
    su -s /bin/sh -c "glance-manage db_sync" glance >> $log_file

    ### [controller01]添加pacemaker资源
    echo "=== TRACE MESSAGE ===>>> " "添加pacemaker资源" | tee -a $log_file
    pcs resource create openstack-glance-registry systemd:openstack-glance-registry op start timeout=120 stop timeout=300 --clone interleave=true
    pcs resource create openstack-glance-api systemd:openstack-glance-api op start timeout=120 stop timeout=300 --clone interleave=true

    pcs constraint order start openstack-keystone-clone then openstack-glance-registry-clone
    pcs constraint order start openstack-glance-registry-clone then openstack-glance-api-clone

    # pcs constraint colocation add openstack-glance-api-clone with openstack-glance-registry-clone

    ### [controller01] 等待image服务启动
    echo "=== TRACE MESSAGE ===>>> " "等待image服务启动，确认服务在vip也开启监听，然后按任意键继续 ...... ...... ...... [-]" | tee -a $log_file
    read answer

    ### [controller01]测试glance服务
    echo "=== TRACE MESSAGE ===>>> " "测试glance服务" | tee -a $log_file
    glance image-list
}

echo -n "confirm to install image [y|n]"
read answer
if [ $answer == "y" ]; then
    install_image
fi