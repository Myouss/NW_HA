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

main-set_kernel_parameters() {
	## disable selinux
	if [ -e /etc/sysconfig/selinux ]; then
		sed -ie 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux
	fi

	if [ -e /etc/selinux/config ]; then
		sed -ie 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
	fi

	## work around for LVM boot where LVM volues are not started on certain SLES/RHEL versions
  if [ -e /etc/sysconfig/lvm ]; then
    sed -ie 's/LVM_ACTIVATED_ON_DISCOVERED="disable"/LVM_ACTIVATED_ON_DISCOVERED="enable"/g' /etc/sysconfig/lvm
  fi

	## Configure cstates and huge pages
	if [ -z "$(cat /etc/default/grub | grep cstate)" ]; then
		main-errhandle_log_info 'Setting boot paramaters'
		echo GRUB_CMDLINE_LINUX_DEFAULT=\"transparent_hugepage=never intel_idle.max_cstate=1 processor.max_cstate=1\" >>/etc/default/grub
		grub2-mkconfig -o /boot/grub2/grub.cfg
		echo $GCP_HOSTNAME >/etc/HOSTNAME
		main-errhandle_log_info '--- Parameters updated. Rebooting'
		reboot
		exit 0
	fi

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
}


main-set_boot_parameters() {
	main-errhandle_log_info 'Checking boot paramaters'

	## disable selinux
	if [ -e /etc/sysconfig/selinux ]; then
	  main-errhandle_log_info "--- Disabling SELinux"
		sed -ie 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux
	fi

	if [ -e /etc/selinux/config ]; then
		main-errhandle_log_info "--- Disabling SELinux"
		sed -ie 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
	fi
	## work around for LVM boot where LVM volues are not started on certain SLES/RHEL versions
  if [ -e /etc/sysconfig/lvm ]; then
    sed -ie 's/LVM_ACTIVATED_ON_DISCOVERED="disable"/LVM_ACTIVATED_ON_DISCOVERED="enable"/g' /etc/sysconfig/lvm
  fi

	## Configure cstates and huge pages
	if [ -z "$(cat /etc/default/grub | grep cstate)" ]; then
	  main-errhandle_log_info "--- Update grub"
		echo GRUB_CMDLINE_LINUX_DEFAULT=\"transparent_hugepage=never intel_idle.max_cstate=1 processor.max_cstate=1\" >>/etc/default/grub
		grub2-mkconfig -o /boot/grub2/grub.cfg
		echo $GCP_HOSTNAME >/etc/HOSTNAME
		main-errhandle_log_info '--- Parameters updated. Rebooting'
		reboot
		exit 0
	fi
}


main-errhandle_log_info() {
	echo "INFO - $1"
	${GCLOUD_CMD} --quiet logging write ${HOSTNAME} "${HOSTNAME} Deployment \"${1}\"" --severity=INFO
}


main-errhandle_log_warning() {
	echo "WARNING - $1"
	${GCLOUD_CMD} --quiet logging write ${HOSTNAME} "${HOSTNAME} Deployment \"${1}\"" --severity=WARNING
}


main-errhandle_log_error() {
	echo "ERROR - Deployment Exited - $1"
  ${GCLOUD_CMD}	--quiet logging write ${HOSTNAME} "${HOSTNAME} Deployment \"${1}\"" --severity=ERROR
	hdb-complete error
}


main-get_os_version() {
	if [[ $(cat /etc/os-release | grep SLES) ]]; then
		export LINUX_DISTRO="SLES"
	elif [[ $(cat /etc/os-release | grep "Red Hat") ]]; then
		export LINUX_DISTRO="RHEL"
	else
		main-errhandle_log_error "Unsupported Linx distribution. Only SLES and RHEL are supported."
	fi
}


main-config_ssh() {
	cat /dev/zero | ssh-keygen -q -N ""
	sed -ie 's/PermitRootLogin no/PermitRootLogin yes/g' /etc/ssh/sshd_config
	service sshd restart
}


main-install_packages() {
	main-errhandle_log_info 'Installing required operating system packages'

	## work around for SLES bug which caused zypper registration problems
	COUNT=0
  if [ $LINUX_DISTRO = "SLES" ]; then
		while [ $(zypper lr | wc -l) -lt 5 ]; do
			main-errhandle_log_info "--- SuSE repositories are not registered. Waiting 10 seconds before trying again"
			sleep 10s
			COUNT=$[$COUNT +1]
			if [ $COUNT -gt 60 ]; then
				main-errhandle_log_error "SuSE repositories didn't register within an acceptable time."
			fi
		done
		sleep 10s
	fi

	## packages to install
	SLES_PACKAGES="libopenssl0_9_8 joe tuned krb5-32bit unrar SAPHanaSR SAPHanaSR-doc pacemaker numactl csh python-pip"
	RHEL_PACKAGES="unar.x86_64 tuned-profiles-sap-hana tuned-profiles-sap-hana-2.7.1-3.el7_3.3 joe resource-agents-sap-hana.x86_64 compat-sap-c++-6 numactl-libs.x86_64 libtool-ltdl.x86_64 nfs-utils.x86_64 pacemaker pcs lvm2.x86_64 compat-sap-c++-5.x86_64 csh autofs"

	## install packages
	if [ $LINUX_DISTRO = "SLES" ]; then
		for package in $SLES_PACKAGES; do
		    zypper in -y $package
		done
		zypper in --force-resolution -y sapconf
		main-errhandle_log_info 'Installing python Google Cloud API client'
		pip install --upgrade google-api-python-client
	  pip install oauth2client --upgrade
	elif [ $LINUX_DISTRO = "RHEL" ]; then
		for package in $RHEL_PACKAGES; do
		    yum -y install $package
		done
	fi
}


main-create_filesystem() {
	if [[ -h /dev/disk/by-id/google-${HOSTNAME}-${2} ]]; then
	  main-errhandle_log_info "--- Creating $1"
	  pvcreate /dev/disk/by-id/google-${HOSTNAME}-$2
		vgcreate vg_$2 /dev/disk/by-id/google-${HOSTNAME}-$2
		lvcreate -l 100%FREE -n vol vg_$2
		if [[ "$2" = "swap" ]]; then
			echo "/dev/vg_$2/vol none $2 defaults,nofail 0 0" >>/etc/fstab
			mkswap /dev/vg_swap/vol
			swapon /dev/vg_swap/vol
		else
			mkfs.$3 /dev/vg_$2/vol
		  echo "/dev/vg_$2/vol $1 $3 defaults,nofail 0 2" >>/etc/fstab
		  mkdir -p $1
		  mount -a
		fi
	fi
}


main-complete() {
  main-errhandle_log_info "INSTANCE DEPLOYMENT COMPLETE"

  ## prepare advanced logs
  if [ ${DEBUG_DEPLOYMENT} = "True" ]; then
    mkdir -p /root/.deploy
    main-errhandle_log_info "--- Debug mode is turned on. Preparing additional logs"
    env > /root/.deploy/${HOSTNAME}_debug_env.log
    cat /var/log/messages | grep startup > /root/.deploy/${HOSTNAME}_debug_startup_script_output.log
    tar -czvf /root/.deploy/${HOSTNAME}_deployment_debug.tar.gz -C /root/.deploy/ .
    main-errhandle_log_info "--- Debug logs stored in /root/.deploy/"
    main-errhandle_log_info "--- Finished"
  fi

  if [[ -f /root/.ssh/config ]]; then
    rm /root/.ssh/config
  fi

  if [ -z $1 ]; then
    exit 0
  else
    exit 1
  fi
}
