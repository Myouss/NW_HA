#!/bin/bash
# ------------------------------------------------------------------------
# Copyright 2016 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Description:	Google Cloud Platform - Deployment Functions
# Version:			3.4
# Date:					12/September/2018
# ------------------------------------------------------------------------

ha-get_settings() {

  main-errhandle_log_info "Getting HA configuration settings"

  VIP=$(gcp-metadata sap_vip)
  VIP_RANGE=$(gcp-metadata sap_vip_secondary_range)
  PRIMARY_NODE=$(gcp-metadata sap_primary_instance)
  SECONDARY_NODE=$(gcp-metadata sap_secondary_instance)
  PRIMARY_NODE_IP=$(ping ${PRIMARY_NODE} -c 1 | head -1 | awk  '{ print $3 }' | sed 's/(//' | sed 's/)//')
  SECONDARY_NODE_IP=$(ping ${SECONDARY_NODE} -c 1 | head -1 | awk  '{ print $3 }' | sed 's/(//' | sed 's/)//')
  PRIMARY_NODE_ZONE=$(gcp-metadata sap_primary_zone)
  SECONDARY_NODE_ZONE=$(gcp-metadata sap_secondary_zone)

  ## check parameters
  if [ -z "$VIP" ] || [ -z "$PRIMARY_NODE" ] || [ -z "$PRIMARY_NODE_IP" ] || [ -z "$PRIMARY_NODE_ZONE" ] || [ -z "$SECONDARY_NODE" ] || [ -z "$SECONDARY_NODE_IP" ] || [ -z "$SECONDARY_NODE_ZONE" ]; then
    main-errhandle_log_warning "High Availability variables were missing or incomplete. Both SAP HANA VM's will be installed and configured but HA will need to be manually setup "
    hdb-complete
  fi

  main-errhandle_log_info "--- SAP virtual IP address will be '${VIP}'"
  main-errhandle_log_info "--- SAP primary node is '$PRIMARY_NODE'"
  main-errhandle_log_info "--- SAP primary node IP is '$PRIMARY_NODE_IP'"
  main-errhandle_log_info "--- SAP primary node zone is '$PRIMARY_NODE_ZONE'"
  main-errhandle_log_info "--- SAP secondary node is '$SECONDARY_NODE'"
  main-errhandle_log_info "--- SAP secondary node IP is '$SECONDARY_NODE_IP'"
  main-errhandle_log_info "--- SAP secondary node zone is '$SECONDARY_NODE_ZONE'"

  mkdir -p /root/.deploy
}


ha-download_scripts() {
  main-errhandle_log_info "Downloading pacemaker-gcp"
  mkdir -p /usr/lib/ocf/resource.d/gcp
  mkdir -p /usr/lib64/stonith/plugins/external
  curl ${DEPLOY_URL}/pacemaker-gcp/alias -o /usr/lib/ocf/resource.d/gcp/alias
  curl ${DEPLOY_URL}/pacemaker-gcp/route -o /usr/lib/ocf/resource.d/gcp/route
  curl ${DEPLOY_URL}/pacemaker-gcp/gcpstonith -o /usr/lib64/stonith/plugins/external/gcpstonith
  chmod +x /usr/lib/ocf/resource.d/gcp/alias
  chmod +x /usr/lib/ocf/resource.d/gcp/route
  chmod +x /usr/lib64/stonith/plugins/external/gcpstonith
}


ha-create_hdb_user() {
  if [ $LINUX_DISTRO = "SLES" ]; then
    HANA_MONITORING_USER="slehasync"
  elif [ $LINUX_DISTRO = "RHEL" ]; then
    HANA_MONITORING_USER="rhelhasync"
  fi

  main-errhandle_log_info "Adding user ${HANA_MONITORING_USER} to $HANA_SID"

  ## create .sql file
  echo "CREATE USER ${HANA_MONITORING_USER} PASSWORD \"${HANA_SYSTEM_PASSWORD}\";" > /root/.deploy/${HOSTNAME}_hdbadduser.sql
  echo "GRANT DATA ADMIN TO ${HANA_MONITORING_USER};" >> /root/.deploy/${HOSTNAME}_hdbadduser.sql
  echo "ALTER USER ${HANA_MONITORING_USER} DISABLE PASSWORD LIFETIME;" >> /root/.deploy/${HOSTNAME}_hdbadduser.sql

  ## run .sql file
  PATH="$PATH:/usr/sap/${HANA_SID}/HDB${HANA_INSTANCE_NUMBER}/exe"
  bash -c "source /usr/sap/*/home/.sapenv.sh && hdbsql -u system -p '${HANA_SYSTEM_PASSWORD}' -i ${HANA_INSTANCE_NUMBER} -I /root/.deploy/${HOSTNAME}_hdbadduser.sql"
}


ha-hdbuserstore() {

  if [ $LINUX_DISTRO = "SLES" ]; then
    HANA_HDBUSERSTORE_KEY="SLEHALOC"
  elif  [ $LINUX_DISTRO = "RHEL" ]; then
    HANA_HDBUSERSTORE_KEY="SAPHANARH2SR"
  fi

  main-errhandle_log_info "Adding hdbuserstore entry '${HANA_HDBUSERSTORE_KEY}' ponting to localhost:3${HANA_INSTANCE_NUMBER}15"

  #add user store
  PATH="$PATH:/usr/sap/${HANA_SID}/HDB${HANA_INSTANCE_NUMBER}/exe"
  bash -c "source /usr/sap/*/home/.sapenv.sh && hdbuserstore SET ${HANA_HDBUSERSTORE_KEY} localhost:3${HANA_INSTANCE_NUMBER}15 ${HANA_MONITORING_USER} '${HANA_SYSTEM_PASSWORD}'"

  #check userstore
  bash -c "source /usr/sap/*/home/.sapenv.sh && hdbsql -U ${HANA_HDBUSERSTORE_KEY} -o /root/.deploy/hdbsql.out -a 'select * from dummy'"

  if [ ! $(cat /root/.deploy/hdbsql.out | sed 's/\"//g') = "X" ]; then
    main-errhandle_log_warning "Unable to connect to HANA after adding hdbuserstore entry. Both SAP HANA systems have been installed and configured but the remainder of the HA setup will need to be manually performed"
    hdb-complete
  fi

  main-errhandle_log_info "--- hdbuserstore connection test successful"
  rm /root/.deploy/hdbsql.out
}


ha-install_secondary_sshkeys() {
  main-errhandle_log_info "Adding ${PRIMARY_NODE} ssh keys to ${SECONDARY_NODE}"
  gcloud compute instances add-metadata $SECONDARY_NODE --metadata "ssh-keys=root:$(cat ~/.ssh/id_rsa.pub)" --zone ${SECONDARY_NODE_ZONE}
  cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

  ## technical not required - but prevents some cluster issues during setup with certain versions of ha-cluster-join
    cat <<EOF > /root/.ssh/config
Host ${SECONDARY_NODE}
  StrictHostKeyChecking no
  LogLevel ERROR
Host ${PRIMARY_NODE}
  StrictHostKeyChecking no
  LogLevel ERROR
EOF
}


ha-install_primary_sshkeys() {
  main-errhandle_log_info "Adding ${SECONDARY_NODE} ssh keys to ${PRIMARY_NODE}"
  gcloud compute instances add-metadata $PRIMARY_NODE --metadata "ssh-keys=root:$(cat /root/.ssh/id_rsa.pub)" --zone ${PRIMARY_NODE_ZONE}
  cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

  ## technical not required - but prevents some cluster issues during setup with certain versions of ha-cluster-join
    cat <<EOF > /root/.ssh/config
Host ${SECONDARY_NODE}
  StrictHostKeyChecking no
  LogLevel ERROR
Host ${PRIMARY_NODE}
  StrictHostKeyChecking no
  LogLevel ERROR
EOF
}


ha-wait_for_secondary() {
  COUNT=0
  main-errhandle_log_info "Waiting for ready signal from ${SECONDARY_NODE} before continuing"
  while [ ! -f /root/.deploy/.${SECONDARY_NODE}.ready ]; do
    COUNT=$[$COUNT +1]
    scp -o StrictHostKeyChecking=no ${SECONDARY_NODE}:/root/.deploy/.${SECONDARY_NODE}.ready /root/.deploy
    main-errhandle_log_info "--- $SECONDARY_NODE is not ready - sleeping for 60 seconds then trying again"
    sleep 60s
    if [ $COUNT -gt 15 ]; then
      main-errhandle_log_warning "$SECONDARY_NODE wasn't ready in time. Both SAP HANA systems have been installed and configured but the remainder of the HA setup will need to be manually performed"
      hdb-complete
    fi
  done
  main-errhandle_log_info "--- $SECONDARY_NODE is now ready - continuing HA setup"
}


ha-wait_for_primary() {
  COUNT=0
  main-errhandle_log_info "Waiting for ready signal from $PRIMARY_NODE before continuing"
  scp -o StrictHostKeyChecking=no ${PRIMARY_NODE}:/root/.deploy/.${PRIMARY_NODE}.ready /root/.deploy

  while [ ! -f /root/.deploy/.${PRIMARY_NODE}.ready ]; do
    COUNT=$[$COUNT +1]
    scp -o StrictHostKeyChecking=no ${PRIMARY_NODE}:/root/.deploy/.${PRIMARY_NODE}.ready /root/.deploy
    main-errhandle_log_info "--- $PRIMARY_NODE is not not ready - sleeping for 60 seconds then trying again"
    sleep 60s
    if [ $COUNT -gt 10 ]; then
      main-errhandle_log_warning "$PRIMARY_NODE wasn't ready in time. Both SAP HANA systems have been installed and configured but the remainder of the HA setup will need to be manually performed"
      hdb-complete
    fi
  done
  main-errhandle_log_info "--- $PRIMARY_NODE is now ready - continuing HA setup"
}


ha-ready(){
  echo "ready" > /root/.deploy/.${HOSTNAME}.ready
}


ha-config_cluster(){
  main-errhandle_log_info "Configuring cluster primivatives"
}


ha-copy_hdb_ssfs_keys(){
  main-errhandle_log_info "Transfering SSFS keys from $PRIMARY_NODE"
  rm /usr/sap/${HANA_SID}/SYS/global/security/rsecssfs/data/SSFS_${HANA_SID}.DAT
  rm /usr/sap/${HANA_SID}/SYS/global/security/rsecssfs/key/SSFS_${HANA_SID}.KEY
  scp -o StrictHostKeyChecking=no ${PRIMARY_NODE}:/usr/sap/${HANA_SID}/SYS/global/security/rsecssfs/data/SSFS_${HANA_SID}.DAT /usr/sap/${HANA_SID}/SYS/global/security/rsecssfs/data/SSFS_${HANA_SID}.DAT
  scp -o StrictHostKeyChecking=no ${PRIMARY_NODE}:/usr/sap/${HANA_SID}/SYS/global/security/rsecssfs/key/SSFS_${HANA_SID}.KEY /usr/sap/${HANA_SID}/SYS/global/security/rsecssfs/key/SSFS_${HANA_SID}.KEY
  chown ${HANA_SID,,}adm:sapsys /usr/sap/${HANA_SID}/SYS/global/security/rsecssfs/data/SSFS_${HANA_SID}.DAT
  chown ${HANA_SID,,}adm:sapsys /usr/sap/${HANA_SID}/SYS/global/security/rsecssfs/key/SSFS_${HANA_SID}.KEY
  chmod g+wrx,u+wrx /usr/sap/${HANA_SID}/SYS/global/security/rsecssfs/data/SSFS_${HANA_SID}.DAT
  chmod g+wrx,u+wrx  /usr/sap/${HANA_SID}/SYS/global/security/rsecssfs/key/SSFS_${HANA_SID}.KEY
}


ha-enable_hsr() {
  main-errhandle_log_info "Enabling HANA System Replication support "
  runuser -l "${HANA_SID,,}adm" -c "hdbnsutil -sr_enable --name=${HOSTNAME}"
}


ha-config_hsr() {
  main-errhandle_log_info "Configuring SAP HANA system replication primary -> secondary"
  runuser -l "${HANA_SID,,}adm" -c "hdbnsutil -sr_register --remoteHost=${PRIMARY_NODE} --remoteInstance=${HANA_INSTANCE_NUMBER} --replicationMode=syncmem --operationMode=logreplay --name=${SECONDARY_NODE}"
}


ha-check_hdb_replication(){
  main-errhandle_log_info "Checking SAP HANA replication status"
  # check status
  bash -c "source /usr/sap/*/home/.sapenv.sh && /usr/sap/${HANA_SID}/HDB${HANA_INSTANCE_NUMBER}/exe/hdbsql -o /root/.deploy/hdbsql.out -a -U ${HANA_HDBUSERSTORE_KEY} 'select distinct REPLICATION_STATUS from SYS.M_SERVICE_REPLICATION'"
  # keep checking status until replication is completed
  while [[ ! $(cat /root/.deploy/hdbsql.out | sed 's/\"//g') = "ACTIVE" ]]; do
    main-errhandle_log_info "--- Replication is still in progressing. Waiting 60 seconds then trying again"
    bash -c "source /usr/sap/*/home/.sapenv.sh && /usr/sap/${HANA_SID}/HDB${HANA_INSTANCE_NUMBER}/exe/hdbsql -o /root/.deploy/hdbsql.out -a -U ${HANA_HDBUSERSTORE_KEY} 'select distinct REPLICATION_STATUS from SYS.M_SERVICE_REPLICATION'"
    sleep 60s
  done
  main-errhandle_log_info "--- Replication in sync. Continuing with HA configuration"
}


ha-check_cluster(){
  main-errhandle_log_info "Checking cluster status"
  while [[ ! $(crm_mon -s | grep "2 nodes online") ]]; do
    main-errhandle_log_info "--- Cluster is not yet online. Waiting 60 seconds then trying again"
    sleep 60s
  done
  main-errhandle_log_info "--- Two cluster nodes are online and ready. Continuing with HA configuration"
}


ha-config_pacemaker_primary() {
  main-errhandle_log_info "Creating cluster on primary node"

  main-errhandle_log_info "--- Creating corosync-keygen"
  corosync-keygen

  if [ $LINUX_DISTRO = "SLES" ]; then
    main-errhandle_log_info "--- Starting csync2"
    script -q -c 'ha-cluster-init -y csync2' > /dev/null 2>&1 &
    main-errhandle_log_info "--- Creating /etc/corosync/corosync.conf"
    cat <<EOF > /etc/corosync/corosync.conf
    totem {
      version:	2
      secauth:	off
      crypto_hash:	sha1
      crypto_cipher:	aes256
      cluster_name:	hacluster
      clear_node_high_bit: yes

      token:		5000
      token_retransmits_before_loss_const: 10
      join:		60
      consensus:	6000
      max_messages:	20

      interface {
        ringnumber:	0
        bindnetaddr:	${PRIMARY_NODE_IP}
        mcastport:	5405
        ttl:		1
      }

      transport: udpu
    }
    logging {
      fileline:	off
      to_stderr:	no
      to_logfile:	no
      logfile:	/var/log/cluster/corosync.log
      to_syslog:	yes
      debug:		off
      timestamp:	on
      logger_subsys {
        subsys:	QUORUM
        debug:	off
      }
    }
    nodelist {
      node {
        ring0_addr: ${PRIMARY_NODE}
        nodeid: 1
      }
    }
    quorum {
      # Enable and configure quorum subsystem (default: off)
      # see also corosync.conf.5 and votequorum.5
      provider: corosync_votequorum
      expected_votes: 1
      two_node: 0
    }
EOF
    main-errhandle_log_info "--- Starting cluster"
    sleep 5s
    script -q -c 'ha-cluster-init -y cluster' > /dev/null 2>&1 &
    wait
  elif [ $LINUX_DISTRO = "RHEL" ]; then
    main-errhandle_log_info "--- Creating /etc/corosync/corosync.conf"
    pcs cluster setup --name hana --local ${PRIMARY_NODE} ${SECONDARY_NODE} --force
    main-errhandle_log_info "--- Starting cluster services & enabling on startup"
    service pacemaker start
    service pscd start
    systemctl enable pcsd.service
    systemctl enable pacemaker
    main-errhandle_log_info "--- Setting hacluster password"
    echo linux | passwd --stdin hacluster
  fi

}


ha-config_pacemaker_secondary() {
  main-errhandle_log_info "Joining ${SECONDARY_NODE} to cluster"

  if [ $LINUX_DISTRO = "SLES" ]; then
    bash -c "ha-cluster-join -y -c ${PRIMARY_NODE} csync2"
    bash -c "ha-cluster-join -y -c ${PRIMARY_NODE} cluster"
    hdb-complete
  elif [ $LINUX_DISTRO = "RHEL" ]; then
    corosync-keygen
    pcs cluster setup --name hana --local ${PRIMARY_NODE} ${SECONDARY_NODE} --force
    service pacemaker start
    service pscd start
    systemctl enable pcsd.service
    systemctl enable pacemaker
    hdb-complete
  fi
}


ha-pacemaker_add_stonith() {
  main-errhandle_log_info "Cluster: Adding STONITH devices"
  if [ $LINUX_DISTRO = "SLES" ]; then
    crm configure primitive STONITH-${PRIMARY_NODE} stonith:external/gcpstonith op monitor interval="300s" timeout="60s" on-fail="restart" op start interval="0" timeout="60s" onfail="restart" params instance_name="${PRIMARY_NODE}" gcloud_path="/usr/local/google-cloud-sdk/bin/gcloud" logging="yes"
    crm configure primitive STONITH-${SECONDARY_NODE} stonith:external/gcpstonith op monitor interval="300s" timeout="60s" on-fail="restart" op start interval="0" timeout="60s" onfail="restart" params instance_name="${SECONDARY_NODE}" gcloud_path="/usr/local/google-cloud-sdk/bin/gcloud" logging="yes"
    crm configure location LOC_STONITH_${PRIMARY_NODE} STONITH-${PRIMARY_NODE} -inf: ${PRIMARY_NODE}
    crm configure location LOC_STONITH_${SECONDARY_NODE} STONITH-${SECONDARY_NODE} -inf: ${SECONDARY_NODE}
  fi
}


ha-pacemaker_add_vip() {
  main-errhandle_log_info "Cluster: Adding virtual IP"
  ping -c 1 -W 1 ${VIP}
  if  [ ! $? -eq 0 ]; then
    if [ $LINUX_DISTRO = "SLES" ]; then
      crm configure primitive rsc_vip_int IPaddr2 params ip=${VIP} cidr_netmask=32 nic="eth0" op monitor interval=10s
      if [[ -n ${VIP_RANGE} ]]; then
        crm configure primitive rsc_vip_gcp ocf:gcp:alias op monitor interval="60s" timeout="15s" op start interval="0" timeout="300s" op stop interval="0" timeout="15s" params alias_ip="${VIP}/32" hostlist="${PRIMARY_NODE} ${SECONDARY_NODE}" gcloud_path="/usr/local/google-cloud-sdk/bin/gcloud" alias_range_name="${VIP_RANGE}" logging="yes" meta priority=10
      else
        crm configure primitive rsc_vip_gcp ocf:gcp:alias op monitor interval="60s" timeout="15s" op start interval="0" timeout="300s" op stop interval="0" timeout="15s" params alias_ip="${VIP}/32" hostlist="${PRIMARY_NODE} ${SECONDARY_NODE}" gcloud_path="/usr/local/google-cloud-sdk/bin/gcloud" logging="yes" meta priority=10
      fi
      crm configure group g-vip rsc_vip_int rsc_vip_gcp
    fi
  else
    main-errhandle_log_warning "- VIP is already associated with another instance. The cluster setup will continue but the floating/virtual IP address will not be added"
  fi
}


ha-pacemaker_config_bootstrap_hdb() {
  main-errhandle_log_info "Cluster: Configuring bootstrap for SAP HANA"
  if [ $LINUX_DISTRO = "SLES" ]; then
    crm configure property no-quorum-policy="ignore"
    crm configure property startup-fencing="true"
    crm configure property stonith-timeout="150s"
    crm configure property stonith-enabled="true"
    crm configure rsc_defaults resource-stickiness="1000"
    crm configure rsc_defaults migration-threshold="5000"
    crm configure op_defaults timeout="600"
  elif [ $LINUX_DISTRO = "RHEL" ]; then
    pcs property set no-quorum-policy="ignore"
    pcs property set startup-fencing="true"
    pcs property set stonith-timeout="150s"
    pcs property set stonith-enabled="true"
    pcs resource defaults default-resource-stickness=1000
    pcs resource defaults default-migration-threshold=5000
    pcs resource op defaults timeout=600s
  fi
}

ha-pacemaker_config_bootstrap_nfs() {
  main-errhandle_log_info "Cluster: Configuring bootstrap for NFS"
  if [ $LINUX_DISTRO = "SLES" ]; then
    crm configure property no-quorum-policy="ignore"
    crm configure property startup-fencing="true"
    crm configure property stonith-timeout="150s"
    crm configure property stonith-enabled="true"
    crm configure rsc_defaults resource-stickiness="100"
    crm configure rsc_defaults migration-threshold="5000"
    crm configure op_defaults timeout="600"
  elif [ $LINUX_DISTRO = "RHEL" ]; then
    pcs property set no-quorum-policy="ignore"
    pcs property set startup-fencing="true"
    pcs property set stonith-timeout="150s"
    pcs property set stonith-enabled="true"
    pcs resource defaults default-resource-stickness=1000
    pcs resource defaults default-migration-threshold=5000
    pcs resource op defaults timeout=600s
  fi
}

ha-pacemaker_add_hana() {
  main-errhandle_log_info "Cluster: Adding HANA nodes"

  if [ $LINUX_DISTRO = "SLES" ]; then
    cat <<EOF > /root/.deploy/cluster.tmp
    primitive rsc_SAPHanaTopology_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER} ocf:suse:SAPHanaTopology \
        operations \$id="rsc_sap2_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER}-operations" \
        op monitor interval="10" timeout="600" \
        op start interval="0" timeout="600" \
        op stop interval="0" timeout="300" \
        params SID="${HANA_SID}" InstanceNumber="${HANA_INSTANCE_NUMBER}"

    clone cln_SAPHanaTopology_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER} rsc_SAPHanaTopology_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER} \
        meta is-managed="true" clone-node-max="1" target-role="Started" interleave="true"
EOF

    crm configure load update /root/.deploy/cluster.tmp

    cat <<EOF > /root/.deploy/cluster.tmp
    primitive rsc_SAPHana_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER} ocf:suse:SAPHana \
        operations \$id="rsc_sap_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER}-operations" \
        op start interval="0" timeout="3600" \
        op stop interval="0" timeout="3600" \
        op promote interval="0" timeout="3600" \
        op monitor interval="10" role="Master" timeout="700" \
        op monitor interval="15" role="Slave" timeout="700" \
        params SID="${HANA_SID}" InstanceNumber="${HANA_INSTANCE_NUMBER}" PREFER_SITE_TAKEOVER="true" \
        DUPLICATE_PRIMARY_TIMEOUT="7200" AUTOMATED_REGISTER="true"

    ms msl_SAPHana_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER} rsc_SAPHana_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER} \
        meta is-managed="true" notify="true" clone-max="2" clone-node-max="1" \
        target-role="Started" interleave="true"

    colocation col_saphana_ip_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER} 2000: g-vip:Started \
        msl_SAPHana_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER}:Master
    order ord_SAPHana_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER} 2000: cln_SAPHanaTopology_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER} \
        msl_SAPHana_${HANA_SID}_HDB${HANA_INSTANCE_NUMBER}
EOF

    crm configure load update /root/.deploy/cluster.tmp
    rm /root/.deploy/cluster.tmp
  fi
}
