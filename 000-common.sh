#!/bin/sh

###
### deploy openstack ha cluster 
### 
### run from the first controller node
###
### M controller nodes + N compute nodes
### ceph deploy runs from the first controller node, and ceph mon + osd run on the compute nodes
###


# ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- 
# setting for ceph
# ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- 
#
# ceph admin node is controller01
# ceph monitor nodes are 3 compute nodes
# ceph osd nodes include all controller nodes + all network nodes + all compute nodes
#

# ceph admin node, run ceph-deploy from this node
# ceph_admin=controller01

# ceph-deploy user
ceph_deploy_user=deploy

# array of ceph monitors
declare -a ceph_mons=(compute01 compute02 compute03)

# array of ceph osds
declare -a ceph_osds=(controller01 controller02 controller03 network01 network02 network03 compute01 compute02 compute03)

# array of ceph nodes, including monitor + osd nodes
declare -a ceph_mons_osds=(controller01 controller02 controller03 network01 network02 network03 compute01 compute02 compute03)

# array of all nodes, including admin + monitor + osd nodes
declare -a ceph_admin_mons_osds=(controller01 controller02 controller03 network01 network02 network03 compute01 compute02 compute03)

# array of ceph osd directory
declare -a ceph_osd_disks=(/disk1 /disk2 /disk3)

#
ceph_osd_host_disk_list=""
for osd in ${ceph_osds[@]};
do
	for disk in ${ceph_osd_disks[@]};
	do
		ceph_osd_host_disk_list=$ceph_osd_host_disk_list$osd":"$disk" "
	done
done

# ceph public network, for client access (r/w), 
# the mon listens on this network, the ceph.conf set mon_host on the mgmt network, so here we must use mgmt network???
ceph_public_network="192.168.101.0"
ceph_public_network_prefix="23"

# ceph cluster network, for heartbeat, object replication and recovery
ceph_cluster_network="172.17.101.0"
ceph_cluster_network_prefix="24"

# ceph-deploy install repository
ceph_deploy_repo=ceph-deploy


# ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- 
# setting for openstack
# ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- 

# array of controllers
declare -a controllers=(controller01 controller02 controller03)

# associate array of controllers and management network interface ip address
declare -A controller_mgmt_nic_map=(["controller01"]="192.168.101.161" ["controller02"]="192.168.101.162" ["controller03"]="192.168.101.163");

# associate array of controllers and tuennel network interface ip address, deprecated
declare -A controller_tunnel_nic_map=(["controller01"]="172.16.101.161" ["controller02"]="172.16.101.161" ["controller03"]="172.16.101.161");

# first controller, run installation scripts here
controller_0=${controllers[0]};

# list of controllers seperated by space
#controller_list_space=${!controller_mgmt_nic_map[@]}
controller_list_space=${controllers[@]}

# list of controllers seperated by comma
controller_list_comma=`echo $controller_list_space | tr " " ","`


# array of networks
declare -a networks=(network01 network02 network03)

# associate array of networks and management network interface ip address
declare -A network_mgmt_nic_map=(["network01"]="192.168.101.164" ["network02"]="192.168.101.165" ["network03"]="192.168.101.166");

# associate array of networks and tuennel network interface ip address
declare -A network_tunnel_nic_map=(["network01"]="172.16.101.164" ["network02"]="172.16.101.165" ["network03"]="172.16.101.166");

# first network node, run network pacemaker command from this node
network_0=${networks[0]}

# list of networks seperated by space
network_list_space=${networks[@]}


# array of hypervisors
declare -a hypervisors=(compute01 compute02 compute03)

# associate array of hypervisors and management network interface ip address
declare -A hypervisor_mgmt_nic_map=(["compute01"]="192.168.101.167" ["compute02"]="192.168.101.168" ["compute03"]="192.168.101.169");

# associate array of hypervisors and tuennel network interface ip address
declare -A hypervisor_tunnel_nic_map=(["compute01"]="172.16.101.167" ["compute02"]="172.16.101.168" ["compute03"]="172.16.101.169");

#
# ---- ---- ---- ---- pacemaker setting ---- ---- ---- ---- 
#

# virtual ip address
virtual_ip="192.168.101.151"

# hacluster user password
hacluster_password="123456"

# controller cluster name
controller_cluster_name="con-cluster"

# network cluster name
network_cluster_name="net-cluster"

#
# ---- ---- ---- ---- galera setting ---- ---- ---- ---- 
# 

# clustercheck username
clustercheck_username="clustercheck_user"

# clustercheck password
clustercheck_password="123456"

#
# ---- ---- ---- ---- rabbitmq setting ---- ---- ---- ---- 
# 

# clustercheck username
rabbitmq_username="openstack"

# clustercheck password
rabbitmq_password="123456"

#
# ---- ---- ---- ---- ceilometer setting ---- ---- ---- ---- 
# 

# redis server virtual ip address, for ceilometer
redis_vip="192.168.101.152"

#
telemetry_secret="123456"

#
# ---- ---- ---- ---- server list in configuration ---- ---- ---- ---- 
# 

# rabbitmq server list in config
rabbit_hosts_list=""
# memcached server list in config
memcached_servers_list=""
# memcached server list in dashboard config
dashboard_memcached_servers_list=""
# mongod server list in config
mongodb_servers_list=""
for ((i=0;i<${#controllers[@]};i+=1))
do
	if [ $i -lt `expr ${#controllers[@]} - 1` ]
	then
		rabbit_hosts_list=$rabbit_hosts_list${controllers[$i]}":5672,"
		memcached_servers_list=$memcached_servers_list${controllers[$i]}":11211,"
		dashboard_memcached_servers_list=$dashboard_memcached_servers_list"'"${controllers[$i]}":11211',"
		mongodb_servers_list=$mongodb_servers_list${controllers[$i]}":27017,"
	else
		rabbit_hosts_list=$rabbit_hosts_list${controllers[$i]}":5672"
		memcached_servers_list=$memcached_servers_list${controllers[$i]}":11211"
		dashboard_memcached_servers_list=$dashboard_memcached_servers_list"'"${controllers[$i]}":11211'"
		mongodb_servers_list=$mongodb_servers_list${controllers[$i]}":27017"
	fi
done

#
# ---- ---- ---- ---- openstack component password ---- ---- ---- ---- 
# 

# 
keystone_db_password="123456"

#
keystone_admin_password="123456"

# 
glance_db_password="123456"

#
glance_ks_password="123456"

#
nova_db_password="123456"

#
nova_ks_password="123456"

#
neutron_db_password="123456"

#
neutron_ks_password="123456"

# neurtorn metadata service agent secret key
metadata_secret_key="123456"

#
cinder_db_password="123456"

#
cinder_ks_password="123456"

# mongodb password
ceilometer_db_password="123456"

#
ceilometer_ks_password="123456"

#
aodh_db_password="123456"

#
aodh_ks_password="123456"


# ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- 
# setting for nagios
# ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- 

#
domain_suffix=".stack.local"

#
nagiosadmin_password="123456"



# echo $rabbit_hosts_list
# echo $memcached_servers_list
# echo $dashboard_memcached_servers_list
# echo $network_0