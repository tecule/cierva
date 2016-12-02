#!/bin/sh

###
### deploy openstack ha cluster 
### 
### run from the ceph deploy node
###

. ../000-common.sh

file_full_name=`basename "$0"`
file_extension="${file_full_name##*.}"
file_name="${file_full_name%.*}"
log_file="/tmp/"$file_name".log"

echo > $log_file

function integrate_openstack_ceph() {
    ### [controller01] 创建pool
    echo "=== TRACE MESSAGE ===>>> " "创建pool" | tee -a $log_file
    ceph osd pool create volumes 128 >> $log_file
    ceph osd pool create images 128 >> $log_file
    ceph osd pool create backups 128 >> $log_file
    ceph osd pool create vms 128 >> $log_file

    ### 所有控制节点（运行glance-api, cinder-volume、cinder-backup服务）需要ceph.conf
    ### 所有计算节点（运行nova-compute服务）需要ceph.conf
    # 所有控制节点和计算节点在安装ceph时已经生成ceph.conf

    ### 所有控制节点（运行glance-api服务）需要安装python-rbd
    # 所有控制节点在安装ceph时已经安装python-rbd

    ### 所有控制节点（运行cinder-volume、cinder-backup服务）需要安装ceph-common
    ### 所有计算节点（运行nova-compute服务）需要安装ceph-common
    # 所有控制节点和计算节点在安装ceph时已经安装ceph-common

    ### [controller01] 创建ceph用户client.cinder、client.image和client.cinder-backup
    echo "=== TRACE MESSAGE ===>>> " "创建ceph用户client.cinder、client.image和client.cinder-backup" | tee -a $log_file
    ceph auth get-or-create client.cinder mon 'allow r' osd 'allow class-read object_prefix rbd_children, allow rwx pool=volumes, allow rwx pool=vms, allow rwx pool=images' >> $log_file
    ceph auth get-or-create client.glance mon 'allow r' osd 'allow class-read object_prefix rbd_children, allow rwx pool=images' >> $log_file
    ceph auth get-or-create client.cinder-backup mon 'allow r' osd 'allow class-read object_prefix rbd_children, allow rwx pool=backups' >> $log_file

    ### [controller01] 生成新用户的keyring
    echo "=== TRACE MESSAGE ===>>> " "生成新用户的keyring" | tee -a $log_file
    ceph auth get-or-create client.glance > ceph.client.glance.keyring
    mv ceph.client.glance.keyring /etc/ceph
    chown glance:glance /etc/ceph/ceph.client.glance.keyring

    ceph auth get-or-create client.cinder > ceph.client.cinder.keyring
    mv ceph.client.cinder.keyring /etc/ceph/
    chown cinder:cinder /etc/ceph/ceph.client.cinder.keyring

    ceph auth get-or-create client.cinder-backup > ceph.client.cinder-backup.keyring
    mv ceph.client.cinder-backup.keyring /etc/ceph
    chown cinder:cinder /etc/ceph/ceph.client.cinder-backup.keyring

    for ((i=1;i<${#controllers[@]};i+=1))
    do
        ### [其他控制节点] 获取glance、cinder和cinder-backup用户的keyring，运行glance-api, cinder-volume和cinder-backup服务的节点需要该配置文件
        echo "=== TRACE MESSAGE ===>>> " ${controllers[$i]} ": 获取glance、cinder和cinder-backup用户的keyring" | tee -a $log_file
        scp /etc/ceph/ceph.client.glance.keyring ${controllers[$i]}:/etc/ceph
        scp /etc/ceph/ceph.client.cinder.keyring ${controllers[$i]}:/etc/ceph
        scp /etc/ceph/ceph.client.cinder-backup.keyring ${controllers[$i]}:/etc/ceph
    done;

    for h in ${hypervisors[@]};
    do
        ### [所有计算节点] 获取cinder用户的keyring，运行nova-compute服务的节点需要该配置文件
        echo "=== TRACE MESSAGE ===>>> " $h ": 获取cinder用户的keyring" | tee -a $log_file
        scp /etc/ceph/ceph.client.cinder.keyring $h:/etc/ceph
    done

    client_cinder_key=`ceph auth get-key client.cinder`
    client_cinder_uuid=`uuidgen`
    echo "client_cinder_uuid="$client_cinder_uuid >> $log_file
    # use double quota to replace with shell variable (inteprate $)
    sed -e "s/CLIENT_CINDER_UUID/$client_cinder_uuid/" openstack-ceph-integration/secret.xml > /tmp/secret.xml
    for h in ${hypervisors[@]};
    do
        ### [所有计算节点] 获取secret.xml
        echo "=== TRACE MESSAGE ===>>> " $h ": 获取secret.xml" | tee -a $log_file
        scp /tmp/secret.xml $h:/tmp >> $log_file

        ### [所有计算节点] 在libvirt中保存client.cinder的secret key
        echo "=== TRACE MESSAGE ===>>> " $h ": 在libvirt中保存client.cinder的secret key" | tee -a $log_file
        ssh $h /bin/bash << EOF
            virsh secret-define --file /tmp/secret.xml
            virsh secret-set-value --secret $client_cinder_uuid --base64 $client_cinder_key
EOF
    done

    for c in ${controllers[@]};
    do
        ### [所有控制节点]修改/etc/glance/glance-api.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/glance/glance-api.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            crudini --set /etc/glance/glance-api.conf DEFAULT show_image_direct_url True
            crudini --set /etc/glance/glance-api.conf glance_store stores rbd
            crudini --set /etc/glance/glance-api.conf glance_store default_store rbd
            crudini --set /etc/glance/glance-api.conf glance_store rbd_store_pool images
            crudini --set /etc/glance/glance-api.conf glance_store rbd_store_user glance
            crudini --set /etc/glance/glance-api.conf glance_store rbd_store_ceph_conf /etc/ceph/ceph.conf
            crudini --set /etc/glance/glance-api.conf glance_store rbd_store_chunk_size 8
            crudini --set /etc/glance/glance-api.conf paste_deployflavor keystone
EOF

        ### [所有控制节点]修改/etc/cinder/cinder.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $c ": 修改/etc/cinder/cinder.conf文件" | tee -a $log_file
        ssh $c /bin/bash << EOF
            crudini --set /etc/cinder/cinder.conf DEFAULT backup_driver cinder.backup.drivers.ceph
            crudini --set /etc/cinder/cinder.conf DEFAULT backup_ceph_conf /etc/ceph/ceph.conf
            crudini --set /etc/cinder/cinder.conf DEFAULT backup_ceph_user cinder-backup
            crudini --set /etc/cinder/cinder.conf DEFAULT backup_ceph_chunk_size 134217728
            crudini --set /etc/cinder/cinder.conf DEFAULT backup_ceph_pool backups
            crudini --set /etc/cinder/cinder.conf DEFAULT backup_ceph_stripe_unit 0
            crudini --set /etc/cinder/cinder.conf DEFAULT backup_ceph_stripe_count 0
            crudini --set /etc/cinder/cinder.conf DEFAULT restore_discard_excess_bytes true
            crudini --set /etc/cinder/cinder.conf DEFAULT enabled_backends ceph

            crudini --set /etc/cinder/cinder.conf ceph volume_driver cinder.volume.drivers.rbd.RBDDriver
            crudini --set /etc/cinder/cinder.conf ceph rbd_pool volumes
            crudini --set /etc/cinder/cinder.conf ceph rbd_ceph_conf /etc/ceph/ceph.conf
            crudini --set /etc/cinder/cinder.conf ceph rbd_flatten_volume_from_snapshot false
            crudini --set /etc/cinder/cinder.conf ceph rbd_max_clone_depth 5
            crudini --set /etc/cinder/cinder.conf ceph rbd_store_chunk_size 4
            crudini --set /etc/cinder/cinder.conf ceph rados_connect_timeout -1
            crudini --set /etc/cinder/cinder.conf ceph glance_api_version 2
            crudini --set /etc/cinder/cinder.conf ceph rbd_user cinder
            crudini --set /etc/cinder/cinder.conf ceph rbd_secret_uuid $client_cinder_uuid
EOF
    done

    for h in ${hypervisors[@]};
    do
        ### [所有计算节点] 获取compute-ceph-suffix
        echo "=== TRACE MESSAGE ===>>> " $h ": 获取compute-ceph-suffix" | tee -a $log_file        
        scp openstack-ceph-integration/compute-ceph-suffix $h:/tmp >> $log_file

        ### [所有计算节点] 配置ceph
        echo "=== TRACE MESSAGE ===>>> " $h ": 配置ceph" | tee -a $log_file
        ssh $h /bin/bash << EOF
            cat /tmp/compute-ceph-suffix | tee -a /etc/ceph/ceph.conf > /dev/null
            mkdir -p /var/run/ceph/guests/ /var/log/qemu/
            chmod -R 777 /var/run/ceph/guests /var/log/qemu/
EOF

        ### [所有计算节点]修改/etc/nova/nova.conf文件 
        echo "=== TRACE MESSAGE ===>>> " $h ": 修改/etc/nova/nova.conf文件" | tee -a $log_file
        ssh $h /bin/bash << EOF
            crudini --set /etc/nova/nova.conf libvirt images_type rbd
            crudini --set /etc/nova/nova.conf libvirt images_rbd_pool vms
            crudini --set /etc/nova/nova.conf libvirt images_rbd_ceph_conf /etc/ceph/ceph.conf
            crudini --set /etc/nova/nova.conf libvirt rbd_user cinder
            crudini --set /etc/nova/nova.conf libvirt rbd_secret_uuid $client_cinder_uuid
            crudini --set /etc/nova/nova.conf libvirt disk_cachemodes \"network=writeback\"
            crudini --set /etc/nova/nova.conf libvirt inject_password false
            crudini --set /etc/nova/nova.conf libvirt inject_key false
            crudini --set /etc/nova/nova.conf libvirt inject_partition -2
            crudini --set /etc/nova/nova.conf libvirt live_migration_flag \"VIR_MIGRATE_UNDEFINE_SOURCE,VIR_MIGRATE_PEER2PEER,VIR_MIGRATE_LIVE,VIR_MIGRATE_PERSIST_DEST,VIR_MIGRATE_TUNNELLED\"
EOF
    done

    echo "重启OpenStack服务，使配置生效"
}

echo -n "confirm to integrate openstack and ceph [y|n]"
read answer
if [ $answer == "y" ]; then
    integrate_openstack_ceph
fi