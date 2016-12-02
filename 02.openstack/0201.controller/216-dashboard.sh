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

function install_dashboard() {
    for c in ${controllers[@]};
    do
        ### [所有控制节点] 修改/etc/haproxy/haproxy.cfg文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/haproxy/haproxy.cfg文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            echo "" >> /etc/haproxy/haproxy.cfg
            echo "listen dashboard_cluster" >> /etc/haproxy/haproxy.cfg
            echo "    bind $virtual_ip:80" >> /etc/haproxy/haproxy.cfg
            echo "    balance source" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcpka" >> /etc/haproxy/haproxy.cfg
            echo "    option  httpchk" >> /etc/haproxy/haproxy.cfg
            echo "    option  tcplog" >> /etc/haproxy/haproxy.cfg
EOF
        for hc in ${controllers[@]};
        do
            echo "    server $hc ${controller_mgmt_nic_map[$hc]}:80 check inter 2000 rise 2 fall 5" | ssh $c "cat >> /etc/haproxy/haproxy.cfg"
        done;

        ### [所有控制节点]安装软件
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件" | tee -a $log_file
        ssh $c yum install -y openstack-dashboard >> $log_file        

        ### [所有控制节点]修改/etc/openstack-dashboard/local_settings文件，所有节点使用相同的SECRET_KEY
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/openstack-dashboard/local_settings文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            sed -i \
                -e 's#OPENSTACK_HOST =.*#OPENSTACK_HOST = "$virtual_ip"#g' \
                -e "s#ALLOWED_HOSTS.*#ALLOWED_HOSTS = ['*',]#g" \
                -e "s#^CACHES#SESSION_ENGINE = 'django.contrib.sessions.backends.cache'\nCACHES#g#" \
                -e "s#locmem.LocMemCache'#memcached.MemcachedCache',\n        'LOCATION' : [ $dashboard_memcached_servers_list ]#g" \
                -e 's#^OPENSTACK_KEYSTONE_URL =.*#OPENSTACK_KEYSTONE_URL = "http://%s:5000/v3" % OPENSTACK_HOST#g' \
                -e "s/^#OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT.*/OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True/g" \
                -e 's/^#OPENSTACK_API_VERSIONS.*/OPENSTACK_API_VERSIONS = {\n    "identity": 3,\n    "image": 2,\n    "volume": 2,\n}\n#OPENSTACK_API_VERSIONS = {/g' \
                -e "s/^#OPENSTACK_KEYSTONE_DEFAULT_DOMAIN.*/OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = 'default'/g" \
                -e 's#^OPENSTACK_KEYSTONE_DEFAULT_ROLE.*#OPENSTACK_KEYSTONE_DEFAULT_ROLE = "user"#g' \
                -e "s#^LOCAL_PATH.*#LOCAL_PATH = '/var/lib/openstack-dashboard'#g" \
                -e "s#^SECRET_KEY.*#SECRET_KEY = '4050e76a15dfb7755fe3'#g" \
                -e "s#'enable_ha_router'.*#'enable_ha_router': True,#g" \
                /etc/openstack-dashboard/local_settings
EOF

        ### [所有控制节点] 修改/etc/httpd/conf/httpd.conf文件，设置HTTPD的监听IP
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/httpd/conf/httpd.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            sed -i -e 's/^Listen.*/Listen ${controller_mgmt_nic_map[$c]}:80/g' /etc/httpd/conf/httpd.conf
EOF

        ### [所有控制节点] 修改/etc/httpd/conf.d/server-status.conf文件，pacemaker监测httpd的配置文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/httpd/conf.d/server-status.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
cat > /etc/httpd/conf.d/server-status.conf << EOF2
<Location /server-status>
    SetHandler server-status
    Order deny,allow
    Deny from all
    Allow from localhost
</Location>
EOF2
EOF
    done;

    ### [controller01] 等待dashboard服务启动
    echo "=== TRACE MESSAGE ===>>> " "等待dashboard服务启动，确认服务在vip也开启监听，然后按任意键继续 ...... ...... ...... [-]" | tee -a $log_file
    read answer
}

echo -n "confirm to install dashboard [y|n]"
read answer
if [ $answer == "y" ]; then
    install_dashboard
fi