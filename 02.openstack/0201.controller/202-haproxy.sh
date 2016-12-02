#!/bin/sh

###
### deploy openstack ha cluster 
### 
### run from the first controller node
###

. ../../000-common.sh

file_full_name=`basename "$0"`
file_extension="${file_full_name##*.}"
file_name="${file_full_name%.*}"
log_file="/tmp/"$file_name".log"

echo > $log_file

function install_haproxy() {
    for c in ${controllers[@]};
    do
        ### [所有控制节点] 安装软件
        echo "=== TRACE MESSAGE ===>>> " $c ": 安装软件" | tee -a $log_file
        ssh $c yum install -y haproxy >> $log_file
    
        ### [所有控制节点] 初始化/etc/haproxy/haproxy.cfg文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 初始化/etc/haproxy/haproxy.cfg文件" | tee -a $log_file
        scp haproxy/haproxy.cfg.base $c:/etc/haproxy/haproxy.cfg
    
        ### [所有控制节点] 修改/etc/rsyslog.d/haproxy.conf文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/rsyslog.d/haproxy.conf文件" | tee -a $log_file
        ssh $c /bin/bash << 'EOF'
            echo "\$ModLoad imudp" >> /etc/rsyslog.d/haproxy.conf;
            echo "\$UDPServerRun 514" >> /etc/rsyslog.d/haproxy.conf;
            echo "local3.* /var/log/haproxy.log" >> /etc/rsyslog.d/haproxy.conf;
            echo "&~" >> /etc/rsyslog.d/haproxy.conf;
EOF
    
        ### [所有控制节点] 修改/etc/sysconfig/rsyslog文件
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/sysconfig/rsyslog文件" | tee -a $log_file
        echo SYSLOGD_OPTIONS=\"-c 2 -r -m 0\" | ssh $c "cat >> /etc/sysconfig/rsyslog"
    
        ### [所有控制节点] 重启rsyslog服务
        echo "=== TRACE MESSAGE ===>>> " $c ": 重启rsyslog服务" | tee -a $log_file
        ssh $c systemctl restart rsyslog
    done;
    
    ### [controller01]在pacemaker集群增加haproxy资源
    echo "=== TRACE MESSAGE ===>>> " "在pacemaker集群增加haproxy资源" | tee -a $log_file
    pcs resource create haproxy systemd:haproxy --clone

    pcs constraint order start virtual-ip then haproxy-clone kind=Optional
    
    pcs constraint colocation add haproxy-clone with virtual-ip
}

echo -n "confirm to install haproxy [y|n]"
read answer
if [ $answer == "y" ]; then
    install_haproxy
fi

