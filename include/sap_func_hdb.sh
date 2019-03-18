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

hdb-calculate_volume_sizes() {

  main-errhandle_log_info "Calculating disk volume sizes"

  LOGSIZE=$(($GCP_MEMSIZE/2))
  LOGSIZE=$((128*(1+($LOGSIZE/128))))
  if [[ $LOGSIZE -ge 512 ]]; then
    LOGSIZE=512
  fi

  DATASIZE=$((($GCP_MEMSIZE*15)/10))

  if [[ ${HANA_SCALEOUT_NODES} -eq 0 ]]; then
    SHAREDSIZE=${GCP_MEMSIZE}
  else
    SHAREDSIZE=$(($GCP_MEMSIZE*(($HANA_SCALEOUT_NODES+3)/4)))
  fi

  ## if worker node, set the SHAREDSIZE to 0
  if [ "${1}" = "worker" ]; then
    SHAREDSIZE=0
  fi

  ## if there is enough space (i.e, multi_sid enabled or if 208GB instances) then double the volume sizes
  PDSSDSIZE=$(($(lsblk --nodeps --bytes --noheadings --output SIZE /dev/sdb)/1024/1024/1024))
  TOTALSIZEx2=$((($DATASIZE+$LOGSIZE)*2 +$SHAREDSIZE))

  if [[ $PDSSDSIZE -gt $TOTALSIZEx2 ]]; then
    main-errhandle_log_info "--- Determined double volume sizes are required"
    main-errhandle_log_info "--- Determined minimum data volume requirement to be $(($DATASIZE*2))"
    LOGSIZE=$(($LOGSIZE*2))
  else
    main-errhandle_log_info "--- Determined minimum data volume requirement to be $DATASIZE"
    main-errhandle_log_info "--- Determined log volume requirement to be $LOGSIZE"
    main-errhandle_log_info "--- Determined shared volume requirement to be $SHAREDSIZE"
  fi
}


hdb-create_sap_data_log_volumes() {

  main-errhandle_log_info 'Building /usr/sap, /hana/shared, /hana/data & /hana/log'

	## create physical volume group for PDSSD
	main-errhandle_log_info '--- Creating physical volume'
	pvcreate /dev/sdb
  main-errhandle_log_info '--- Creating volume group'
	vgcreate vg_hana /dev/sdb

	## create logical volumes
	main-errhandle_log_info '--- Creating logical volumes'
	lvcreate -L 32G -n sap vg_hana
	lvcreate -L ${LOGSIZE}G -n log vg_hana
	lvcreate -l 100%FREE -n data vg_hana

	## format file systems
  main-errhandle_log_info '--- Formatting filesystems'
	mkfs -t xfs /dev/vg_hana/sap
	mkfs -t xfs /dev/vg_hana/log
	mkfs -t xfs /dev/vg_hana/data

	## create mount points
	main-errhandle_log_info '--- Mounting filesystem'
	mkdir -p /hana/data /hana/log /hana/shared /hanabackup /usr/sap

	## add to fstab
	echo "/dev/vg_hana/data /hana/data xfs defaults,nofail 1 2" >> /etc/fstab
	echo "/dev/vg_hana/log /hana/log xfs nobarrier,defaults,nofail 1 2" >> /etc/fstab
	echo "/dev/vg_hana/sap /usr/sap xfs defaults,nofail 1 2" >> /etc/fstab

	## mount file systems
	mount -a

	## check mount points exist
	if [[ ! $(cat /etc/mtab | grep hana) ]]; then
		main-errhandle_log_error "HANA Data and Log volume failed to create correctly"
	fi

  ## create base folders
  mkdir -p /hana/data/${HANA_SID} /hana/log/${HANA_SID}
  chmod 777 /hana/data/${HANA_SID} /hana/log/${HANA_SID}
}


hdb-create_shared_volume() {

  ## create physical volume group for PDSSD
  main-errhandle_log_info 'Building /hana/shared'
	main-errhandle_log_info '--- Creating physical volume'
	pvcreate /dev/sdb
  main-errhandle_log_info '--- Creating volume group'
	vgcreate vg_hana /dev/sdb

	## create hana shared logical volume & backup logical file system
	lvcreate -L ${SHAREDSIZE}G -n shared vg_hana

	## create filesystems
	mkfs -t xfs /dev/vg_hana/shared

	## add mount points to fstab
	echo "/dev/vg_hana/shared /hana/shared xfs defaults,nofail 1 2" >> /etc/fstab
	mount -av
}


hdb-create_backup_volume() {
  ## create physical volume group for Backup PD-HDD
  main-errhandle_log_info 'Building /hanabackup'

	main-errhandle_log_info '--- Creating physical volume group'
	pvcreate /dev/sdc
  main-errhandle_log_info '--- Creating volume group'
	vgcreate vg_hanabackup /dev/sdc

  main-errhandle_log_info '--- Creating logical volume'
  lvcreate -l 100%FREE -n backup vg_hanabackup

  ## create filesystems
  main-errhandle_log_info '--- Formatting filesystem'
  mkfs -t xfs /dev/vg_hanabackup/backup

  ## add mount points to fstab
  main-errhandle_log_info '--- Mounting filesystem'
  echo "/dev/vg_hanabackup/backup /hanabackup xfs defaults,nofail 1 2" >> /etc/fstab
  mount -a

  ## check mount points exist
  if [[ ! $(cat /etc/mtab | grep hanabackup) ]]; then
    main-errhandle_log_error "Backup volume failed to create correctly"
  fi
}


hdb-set_kernel_parameters(){
  main-errhandle_log_info 'Setting kernel paramaters'
  echo "vm.pagecache_limit_mb = 0" >> /etc/sysctl.conf
  echo "vm.pagecache_limit_ignore_dirty=0" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_slow_start_after_idle=0" >> /etc/sysctl.conf
  echo "kernel.numa_balancing = 0" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_slow_start_after_idle=0" >> /etc/sysctl.conf
  echo "net.core.somaxconn = 4096" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_tw_reuse = 1" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_tw_recycle = 1" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_timestamps = 1" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_syn_retries = 8" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_wmem = 4096 16384 4194304" >> /etc/sysctl.conf
  sysctl -p

  main-errhandle_log_info 'Preparing tuned'
  mkdir -p /etc/tuned/sap-hana/
  cp /usr/lib/tuned/sap-hana/tuned.conf /etc/tuned/sap-hana/
	systemctl start tuned
  systemctl enable tuned
	tuned-adm profile sap-hana
}


hdb-prepare_system() {
	main-errhandle_log_info "Preparing system for SAP HANA"
  mkdir -p /etc/tuned/sap-hana/
  cp /usr/lib/tuned/sap-hana/tuned.conf /etc/tuned/sap-hana/
	main-errhandle_log_info "--- Configuring tuned"
	systemctl start tuned
  systemctl enable tuned
	tuned-adm profile sap-hana
	main-errhandle_log_info "--- Configuring sapinit"
	mkdir -p /etc/systemd/system/sapinit.service.d
	touch /etc/systemd/system/sapinit.service.d/type.conf
	echo "[Service]" >> /etc/systemd/system/sapinit.service.d/type.conf
	echo "Type=oneshot" >> /etc/systemd/system/sapinit.service.d/type.conf
	systemctl daemon-reload
}


hdb-download_media() {
	main-errhandle_log_info "Downloading HANA media from $HANA_MEDIA_BUCKET"
	mkdir -p /hana/shared/media

  ## download unrar from GCS. Fix for RHEL missing unrar and SAP packaging change which stoppped unar working.
  curl ${DEPLOY_URL}/bin/unrar -o /root/.deploy/unrar
  chmod a=wrx /root/.deploy/unrar

  ## download SAP HANA media
  /usr/local/google-cloud-sdk/bin/gsutil rsync -x ".part*$|IMDB_SERVER*.SAR$" gs://${HANA_MEDIA_BUCKET} /hana/shared/media/

 	## check extraction worked
	if  [ ! $? -eq 0 ]; then
		main-errhandle_log_warning "HANA Media Download Failed - The deployment will continue but SAP HANA will not be installed"
    hdb-complete
	fi
}


hdb-create_install_cfg() {

  ## output settings to log
  main-errhandle_log_info "Creating HANA installation configuration file /root/.deploy/${HOSTNAME}_hana_install.cfg"
  main-errhandle_log_info "--- SAP HANA will be installed with an additional '${HANA_SCALEOUT_NODES}' worker nodes"

  main-errhandle_log_info "--- SAP HANA media bucket is '$HANA_MEDIA_BUCKET'"
	main-errhandle_log_info "--- SAP HANA SID will be '$HANA_SID'"
  main-errhandle_log_info "--- SAP HANA instance number will be '${HANA_INSTANCE_NUMBER}'"
  main-errhandle_log_info "--- SAP HANA sidadm UID will will be '${HANA_SIDADM_UID}'"
  main-errhandle_log_info "--- SAP HANA sapsys GID will be '${HANA_SAPSYS_GID}'"

  ## check parameters
  if [ -z "$HANA_MEDIA_BUCKET" ] || [ -z "$HANA_SYSTEM_PASSWORD" ] || [ -z "$HANA_SIDADM_PASSWORD" ] || [ -z "$HANA_SID" ] || [ -z "$HANA_SID" ] || [ -z "$HANA_SID" ]; then
    main-errhandle_log_warning "SAP HANA variables were missing or incomplete in the deployment manager template. The deployment has finished and ready for SAP HANA, but SAP HANA will need to be installed manually"
    hdb-complete
  fi

  ## If HA configuru
  if [ -n "$VIP" ]; then
      AUTOSTART="n"
      main-errhandle_log_info "--- SAP HANA automatic start on boot is disabled and is now under cluster control"
  else
      AUTOSTART="y"
  fi

  ## create hana_install.cfg file
  mkdir -p /root/.deploy
  echo "[Server]" >/root/.deploy/${HOSTNAME}_hana_install.cfg
  echo "sid=${HANA_SID}" >>/root/.deploy/${HOSTNAME}_hana_install.cfg
  echo "number=${HANA_INSTANCE_NUMBER}" >>/root/.deploy/${HOSTNAME}_hana_install.cfg
  echo "sapadm_password=${HANA_SIDADM_PASSWORD}" >>/root/.deploy/${HOSTNAME}_hana_install.cfg
  echo "password=${HANA_SIDADM_PASSWORD}" >>/root/.deploy/${HOSTNAME}_hana_install.cfg
  echo "system_user_password=${HANA_SYSTEM_PASSWORD}" >>/root/.deploy/${HOSTNAME}_hana_install.cfg
  echo "autostart=${AUTOSTART}" >>/root/.deploy/${HOSTNAME}_hana_install.cfg
  echo "userid=${HANA_SIDADM_UID}" >>/root/.deploy/${HOSTNAME}_hana_install.cfg
  echo "groupid=${HANA_SAPSYS_GID}" >>/root/.deploy/${HOSTNAME}_hana_install.cfg
}


hdb-extract_media() {
  main-errhandle_log_info "Extracting SAP HANA media"
  cd /hana/shared/media/

  if [[ -f /root/.deploy/unrar ]]; then
    /root/.deploy/unrar -o+ x "*part1.exe" >/dev/null
  elif [ $LINUX_DISTRO = "SLES" ]; then
    unrar -o+ x "*part1.exe" >/dev/null
  elif [ $LINUX_DISTRO = "RHEL" ]; then
    for FILE in $(ls *.exe); do
      unar -f $FILE >/dev/null
    done
  fi

  ## check extraction worked
  if  [ ! $? -eq 0 ]; then
    main-errhandle_log_error "HANA media extraction failed. Please ensure the correct media is uploaded to your GCS bucket"
  fi
}


hdb-install() {
	main-errhandle_log_info 'Installing SAP HANA'
	/hana/shared/media/51*/DATA_UNITS/HDB_LCM_LINUX_X86_64/hdblcm --configfile=/root/.deploy/${HOSTNAME}_hana_install.cfg -b

	## check extraction worked
	if  [ ! $? -eq 0 ]; then
		main-errhandle_log_error "HANA Installation Failed. The server deployment is complete but SAP HANA is not deployed. Manual SAP HANA installation will be required"
	fi
}


hdb-upgrade(){
	if [ $(ls /hana/shared/media/IMDB_SERVER*.SAR) ]; then
	  main-errhandle_log_info "An SAP HANA update was found in GCS. Performing the upgrade:"
	  main-errhandle_log_info "--- Extracting HANA upgrade media"
		cd /hana/shared/media
		/usr/sap/*/SYS/exe/hdb/SAPCAR -xvf "IMDB_SERVER*.SAR"
		cd SAP_HANA_DATABASE
	  main-errhandle_log_info "--- Upgrading Database"
		./hdblcm --configfile=/root/.deploy/${HOSTNAME}_hana_install.cfg --action=update --ignore=check_signature_file --update_execution_mode=optimized --batch
		if  [ ! $? -eq 0 ]; then
		    main-errhandle_log_warning "SAP HANA Database revision upgrade failed to install."
		fi
	fi
}


hdb-install_afl() {
  if [ $(/usr/local/google-cloud-sdk/bin/gsutil ls gs://${HANA_MEDIA_BUCKET}/IMDB_AFL*) ]; then
    main-errhandle_log_info "SAP AFL was found in GCS. Installing SAP AFL addon"
    main-errhandle_log_info "--- Downloading AFL media"
    /usr/local/google-cloud-sdk/bin/gsutil cp gs://${HANA_MEDIA_BUCKET}/IMDB_AFL*.SAR /hana/shared/media/
    main-errhandle_log_info "--- Extracting AFL media"
    cd /hana/shared/media
    /usr/sap/*/SYS/exe/hdb/SAPCAR -xvf "IMDB_AFL*.SAR"
    cd SAP_HANA_AFL
    main-errhandle_log_info "--- Installing AFL"
    ./hdbinst --sid=${HANA_SID}
  fi
}


hdb-set_parameters() {
  bash -c "source /usr/sap/*/home/.sapenv.sh && hdbsql -d SYSTEMDB -u SYSTEM -p $HANA_SYSTEM_PASSWORD -i $HANA_INSTANCE_NUMBER \"ALTER SYSTEM ALTER CONFIGURATION ('$1', 'SYSTEM') SET ('$2','$3') = '$4' with reconfigure\""
  if  [ ! $? -eq 0 ]; then
    bash -c "source /usr/sap/*/home/.sapenv.sh && hdbsql -u SYSTEM -p $HANA_SYSTEM_PASSWORD -i $HANA_INSTANCE_NUMBER \"ALTER SYSTEM ALTER CONFIGURATION ('$1', 'SYSTEM') SET ('$2','$3') = '$4' with reconfigure\""
  fi
}


hdb-config_backup() {
  main-errhandle_log_info 'Configuring backup locations to /hanabackup'
  mkdir -p /hanabackup/data/${HANA_SID}
  mkdir -p /hanabackup/log/${HANA_SID}
  chown -R root:sapsys /hanabackup
  chmod -R g=wrx /hanabackup
  hdb-set_parameters global.ini persistence basepath_databackup /hanabackup/data/${HANA_SID}
  hdb-set_parameters global.ini persistence basepath_logbackup /hanabackup/log/${HANA_SID}
}


hdb-get_settings() {
	HANA_MEDIA_BUCKET=$(gcp-metadata sap_hana_deployment_bucket)
  HANA_SID=$(gcp-metadata sap_hana_sid)
  HANA_SIDADM_PASSWORD=$(gcp-metadata sap_hana_sidadm_password)
  HANA_SYSTEM_PASSWORD=$(gcp-metadata sap_hana_system_password)
  HANA_INSTANCE_NUMBER=$(gcp-metadata sap_hana_instance_number)
  HANA_SCALEOUT_NODES=$(gcp-metadata sap_hana_scaleout_nodes)
  HANA_SIDADM_UID=$(gcp-metadata sap_hana_sidadm_uid)
  HANA_SAPSYS_GID=$(gcp-metadata sap_hana_sapsys_gid)
  VIP=$(gcp-metadata sap_vip)

  ## fix instance number
  if [[ -n "${HANA_INSTANCE_NUMBER}" ]]; then
    if [[ $HANA_INSTANCE_NUMBER -lt 10 ]]; then
     HANA_INSTANCE_NUMBERtmp="0${HANA_INSTANCE_NUMBER}"
     HANA_INSTANCE_NUMBER=${HANA_INSTANCE_NUMBERtmp}
    fi
  fi

  ## Add defaults if they're missing from instance settings
  if [ -z "$HANA_SAPSYS_GID" ]; then
    HANA_SAPSYS_GID=79
  fi

  if [ -z "$HANA_SIDADM_UID" ]; then
    HANA_SIDADM_UID=900
  fi

  if [[ $GCP_STARTUP = *"worker"* ]]; then
     HANA_MASTER_NODE="$(hostname | rev | cut -d"w" -f2-999 | rev)"
  else
     HANA_MASTER_NODE=${HOSTNAME}
  fi

  ## check you have access to the bucket
  /usr/local/google-cloud-sdk/bin/gsutil ls gs://${HANA_MEDIA_BUCKET}
  if  [ ! $? -eq 0 ]; then
    HANA_MEDIA_BUCKET=""
  fi

  ## Remove passwords from metadata
  gcp-remove_metadata sap_hana_system_password
  gcp-remove_metadata sap_hana_sidadm_password
}


hdb-config_nfs() {
  if [ ! ${HANA_SCALEOUT_NODES} = "0" ]; then

    main-errhandle_log_info "Configuring NFS for scale-out"

		## turn off NFS4 support
		sed -ie 's/NFS4_SUPPORT="yes"/NFS4_SUPPORT="no"/g' /etc/sysconfig/nfs

		main-errhandle_log_info "--- Starting NFS server"
		if [ $LINUX_DISTRO = "SLES" ]; then
			systemctl start nfsserver
		elif [ $LINUX_DISTRO = "RHEL" ]; then
			systemctl start nfs
		fi

		## Check NFS has started - Fix for bug which occasionally causes a delay in the NFS start-up
		while [ $(ps aux | grep nfs | wc -l) -le 3 ]; do
			main-errhandle_log_info "--- NFS server not running. Waiting 10 seconds then trying again"
			sleep 10s
			if [ $LINUX_DISTRO = "SLES" ]; then
				systemctl start nfsserver
			elif [ $LINUX_DISTRO = "RHEL" ]; then
				systemctl start nfs
			fi
		done

		## Enable & start NFS service
		main-errhandle_log_info "--- Enabling NFS server at boot up"
		if [ $LINUX_DISTRO = "SLES" ]; then
			systemctl enable nfsserver
		elif [ $LINUX_DISTRO = "RHEL" ]; then
			systemctl enable nfs
		fi

		## Adding file system to NFS exports file systems
		for i in $(seq 1 ${HANA_SCALEOUT_NODES}); do
		  echo "/hana/shared `hostname`w$i(rw,no_root_squash,sync,no_subtree_check)" >>/etc/exports
		  echo "/hanabackup `hostname`w$i(rw,no_root_squash,sync,no_subtree_check)" >>/etc/exports
		done

		## manually exporting file systems
		exportfs -rav
	fi
}


hdb-install_scaleout_nodes() {
  if [ ! ${HANA_SCALEOUT_NODES} = "0" ]; then
    main-errhandle_log_info "Installing ${HANA_SCALEOUT_NODES} additional worker nodes"

    ## Set basepath
    hdb-set_parameters global.ini persistence basepath_shared no

    ## Check each host is online and ssh'able before contining
		COUNT=0
		for i in $(seq 1 ${HANA_SCALEOUT_NODES}); do
			while [[ $(ssh -o StrictHostKeyChecking=no ${HOSTNAME}w${i} "echo 1") != [1] ]]; do
				COUNT=$[$COUNT +1]
				main-errhandle_log_info "--- ${HOSTNAME}w${i} is not accessible via SSH - sleeping for 10 seconds and trying again"
				sleep 10
				if [ $COUNT -gt 60 ]; then
					main-errhandle_log_error "Unable to add additional HANA hosts. Couldn't connect to additional ${HOSTNAME}w${i} via SSH"
				fi
			done
		done

		## get passwords from install file
		HANA_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><Passwords>"
		HANA_XML+="<password><![CDATA[$(cat /root/.deploy/${HOSTNAME}_hana_install.cfg | grep password | grep -v sapadm | grep -v system | cut -d"=" -f2 | head -1)]]></password>"
		HANA_XML+="<sapadm_password><![CDATA[$(cat /root/.deploy/${HOSTNAME}_hana_install.cfg | grep sapadm_password | cut -d"=" -f2)]]></sapadm_password>"
		HANA_XML+="<system_user_password><![CDATA[$(cat /root/.deploy/${HOSTNAME}_hana_install.cfg | grep system_user_password | cut -d"=" -f2 | head -1)]]></system_user_password></Passwords>"

    ## Add nodes 8 at a time (prevents instability when adding over 32 nodes)
    cd /hana/shared/*/hdblcm

		for i in $(seq 1 ${HANA_SCALEOUT_NODES}); do
      main-errhandle_log_info "--- Adding node ${HOSTNAME}w${i}"
      echo $HANA_XML | ./hdblcm --action=add_hosts --addhosts=${HOSTNAME}w${i} --root_user=root --listen_interface=global --read_password_from_stdin=xml -b
      if  [ ! $? -eq 0 ]; then
        main-errhandle_log_error "Failed to install additional SAP HANA worker nodes"
      fi
    done

    ## Post deployment & installation cleanup
    hdb-complete
  fi
}


hdb-mount_nfs() {
  main-errhandle_log_info 'Mounting NFS volumes /hana/shared & /hanabackup'
  echo "$(hostname | rev | cut -d"w" -f2-999 | rev):/hana/shared /hana/shared nfs	nfsvers=3,rsize=32768,wsize=32768,hard,intr,timeo=18,retrans=200 0 0" >>/etc/fstab
  echo "$(hostname | rev | cut -d"w" -f2-999 | rev):/hanabackup /hanabackup nfs	nfsvers=3,rsize=32768,wsize=32768,hard,intr,timeo=18,retrans=200 0 0" >>/etc/fstab

  ## mount file systems
  mount -a

  ## check /hana/shared is mounted before continuing
  COUNT=0
  while [ ! $(cat /etc/mtab | grep shared) ]; do
    COUNT=$[$COUNT +1]
    main-errhandle_log_info "--- /hana/shared is not mounted. Waiting 10 seconds and trying again"
    sleep 10s
    mount -a
    if [ ${COUNT} -gt 120 ]; then
      main-errhandle_log_error "/hana/shared is not mounted - Unable to continue"
    fi
  done
}


hdb-complete() {
  # if no error, display complete message
  if [ -z $1 ]; then
    main-errhandle_log_info "INSTANCE DEPLOYMENT COMPLETE"
  fi

  ## prepare advanced logs
  if [ ${DEBUG_DEPLOYMENT} = "True" ]; then
    mkdir -p /root/.deploy
    main-errhandle_log_info "--- Debug mode is turned on. Preparing additional logs"
    cp -R /var/tmp/hdb*${HANA_SID}*/ /root/.deploy/
    env > /root/.deploy/${HOSTNAME}_debug_env.log
    cat /var/log/messages | grep startup > /root/.deploy/${HOSTNAME}_debug_startup_script_output.log
    tar -czvf /root/.deploy/${HOSTNAME}_deployment_debug.tar.gz -C /root/.deploy/ .
    ## Upload logs to GCS bucket & display complete message
    if [ -n "${HANA_MEDIA_BUCKET}" ]; then
      main-errhandle_log_info "--- Uploading logs to Google Cloud Storage bucket"
      /usr/local/google-cloud-sdk/bin/gsutil cp /tmp/${HOSTNAME}_*.log gs://$HANA_MEDIA_BUCKET/logs/
      /usr/local/google-cloud-sdk/bin/gsutil cp /root/.deploy/${HOSTNAME}_deployment_debug.tar.gz  gs://$HANA_MEDIA_BUCKET/logs/
    fi
    main-errhandle_log_info "--- Finished"
  fi

  if [[ -f /root/.ssh/config ]]; then
    rm /root/.ssh/config
  fi

  ## exit
  if [ -z $1 ]; then
    exit 0
  else
    exit 1
  fi
}


hdb-backup() {
  main-errhandle_log_info "Creating HANA backup ${1}"
  PATH="$PATH:/usr/sap/${HANA_SID}/HDB${HANA_INSTANCE_NUMBER}/exe"
  bash -c "source /usr/sap/*/home/.sapenv.sh && hdbsql -u system -p $HANA_SYSTEM_PASSWORD -i $HANA_INSTANCE_NUMBER \"BACKUP DATA USING FILE ('${1}')\""
  bash -c "source /usr/sap/*/home/.sapenv.sh && hdbsql -u system -p $HANA_SYSTEM_PASSWORD -d SYSTEMDB -i $HANA_INSTANCE_NUMBER \"BACKUP DATA for SYSTEMDB USING FILE ('${1}_SYSTEMDB')\""
}


hdb-stop() {
  main-errhandle_log_info "Stopping SAP HANA"
  su - ${HANA_SID,,}adm -c "HDB stop"
}

hdb-stop_nowait(){
    /usr/sap/${HANA_SID}/SYS/exe/hdb/sapcontrol -prot NI_HTTP -nr ${HANA_INSTANCE_NUMBER} -function Stop
}

hdb-start() {
  main-errhandle_log_info "Starting SAP HANA"
  su - ${HANA_SID,,}adm -c "HDB start"
}

hdb-start_nowait(){
    /usr/sap/${HANA_SID}/SYS/exe/hdb/sapcontrol -prot NI_HTTP -nr ${HANA_INSTANCE_NUMBER} -function Start
}


hdb-install_worker_sshkeys() {
  if [ ! ${HANA_SCALEOUT_NODES} = "0" ]; then
    main-errhandle_log_info "Installing SSH keys"
    COUNT=0
  	for i in $(seq 1 ${HANA_SCALEOUT_NODES}); do
      ERR=1
      while [ ! ${ERR} -eq 0 ]; do
        gcloud compute instances add-metadata ${HANA_MASTER_NODE}w${i} --metadata "ssh-keys=root:$(cat ~/.ssh/id_rsa.pub)"
        ERR=$?
        ## if gcloud returns an error, keep trying.
        if  [ ! $? -eq 0 ]; then
          main-errhandle_log_info "--- Unable to add keys to ${HANA_MASTER_NODE}w${i}. Waiting 10 seconds then trying again"
    			sleep 10s
          ## if more than 60 failures, give up
          if [ $COUNT -gt 60 ]; then
            main-errhandle_log_error "Unable to add SSH keys to all scale-out worker hosts"
          fi
        fi
      done
    done
  fi
}
