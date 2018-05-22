#!/bin/bash
# Enable bash debug logging and Exit 1 in case of any unmanaged issue
set -xe

# vHost-Net Affinity and CPU Pinning Script. Also disable Multi-Queue
# This script is meant to be executed as a CronJob script.
# For any running VSFO VM the script disable the Multi-Queue
# and checks the current QEMU Emulation Threads Affinity.
# Eventually it's enforced on the system cores. After that,
# for both vHost-Net EXT and vFAB CPU Pinning is done on specific
# CPU cores. Lastly, also the process scheduling of those
# process will be changed to Real-Time

# Exit Codes
# 0 - Everything is fine
# 1 - Something went wrong

# LOG FILE
_LOGS="/var/log/vhost-net-tuning.log"

# Check the total number of VMs and exit it if is less than zero
_DOMAIN=$(virsh list | awk '/running/ {print $2}' | wc -l)
if (( ${_DOMAIN} == 0 )); then
	echo "No running VNF here." |& tee -a ${_LOGS}
	exit 0
fi

###### IRQ Pinning ######
_IRQCORE="1"
###### QEMU Emulation Thread Process Affinity for NUMA0 ######
_QEMUCORESNUMA0="0-5,24-29"
###### QEMU Emulation Thread Process Affinity for NUMA1 ######
_QEMUCORESNUMA1="0-5,24-29"
###### QEMU vHost-Net Ext1 Process Pinning for NUMA0 ######
_PINEXT1NUMA0="4"
###### QEMU vHost-Net vFAB1 Process Pinning for NUMA0 ######
_PINVFAB1NUMA0="5"
###### QEMU vHost-Net BP1 Process Pinning for NUMA0 ######
_PINBP1NUMA0="2"
###### QEMU vHost-Net BP2 Process Pinning for NUMA0 ######
_PINBP2NUMA0="3"
###### QEMU vHost-Net Ext1 Process Pinning for NUMA1 ######
_PINEXT1NUMA1="4"
###### QEMU vHost-Net vFAB1 Process Pinning for NUMA1 ######
_PINVFAB1NUMA1="5"
###### QEMU vHost-Net BP1 Process Pinning for NUMA1 ######
_PINBP1NUMA1="2"
###### QEMU vHost-Net BP2 Process Pinning for NUMA1 ######
_PINBP2NUMA1="3"

###### Enable BP1 and BP2 CPU Pinning
_BPPINNING=true

###### Enable IRQ PINNING
_IRQPINNING=true

_NAMEPATTERN="^.*VSFO.*$"
_PROJECTPATTERN="EPC-Ericsson|admin"

# For each KVM Domain do the following
for _DOMAIN in $(virsh list | awk '/running/ {print $2}')
do
	echo -e "##########\n### vHost Net Tuning initialized at $(date)" |& tee -a ${_LOGS}
	# Before doing anything, check if the VNF is a VSFO and the Project name as well
	_NAME=$(virsh dumpxml ${_DOMAIN} | grep nova:name | sed -e 's/<[^>]*>//g' -e 's/  //g')
	_PROJECT=$(virsh dumpxml ${_DOMAIN} | grep nova:project | sed -e 's/<[^>]*>//g' -e 's/  //g')
	_NAMESTATUS=$(echo ${_NAME} | grep -E -q "${_NAMEPATTERN}" && echo true || echo false)
	_PROJECTSTATUS=$(echo ${_PROJECT} | grep -E -q "${_PROJECTPATTERN}" && echo true || echo false)
	# If both NAME and PROJECT match the defined criterias go ahead
	if ${_NAMESTATUS} && ${_PROJECTSTATUS}; then
		echo "### This Compute node has an Ericsson vEPG running - ${_NAME}" |& tee -a ${_LOGS}
		# Disable Multi-Queue for every physical interface member of the bond
		_IRQBALANCE_ARGS="IRQBALANCE_ARGS=\""
		_IRQLIST=""
		_BOND=$(vif list --get 0 | awk '/vif0\/0/ {print $3}')
		for _SLAVE in $(cat /sys/class/net/${_BOND}/bonding/slaves);
		do
			echo "### Disabling MultiQueue for ${_BOND} interface ${_SLAVE}" |& tee -a ${_LOGS}
			_MQCONFIG=$(/sbin/ethtool --show-channels ${_SLAVE} | grep -A4 "Current hardware settings" | awk '/Combined/ {print $2}')
			if [[ "${_MQCONFIG}" != "1" ]]; then
				# Print the current configuration
				/sbin/ethtool --show-channels ${_SLAVE} |& tee -a ${_LOGS}
				# Disable multiqueue
				/sbin/ethtool --set-channels ${_SLAVE} combined 1 |& tee -a ${_LOGS}
				# shutdown the interface in order make sure the multiqueue config is effective
				/sbin/ip link set down ${_SLAVE} |& tee -a ${_LOGS}
				# Sleep to make sure everything is down
				sleep 5s
				# Restore the interface state
				/sbin/ip link set up ${_SLAVE} |& tee -a ${_LOGS}
			fi
			for _IRQ in $(tuna --show_irqs | grep ${_SLAVE} | awk '{print $1}')
			do
				# Create the IRQ Balancer Ban configuration
				_IRQBALANCE_ARGS="$(echo ${_IRQBALANCE_ARGS} --banirq=${_IRQ})"
				# Generate the list of IRQs
				if [[ "${_IRQLIST}" == "" ]]; then
					_IRQLIST="$(echo ${_IRQ})"
				else
					_IRQLIST="$(echo ${_IRQLIST},${_IRQ})"
				fi
			done
		done
		_IRQBALANCE_ARGS="$(echo ${_IRQBALANCE_ARGS}\")"
		if ${_IRQPINNING}; then
			echo "### IRQ Pinning for any interface in the ${_BOND} LAG" |& tee -a ${_LOGS}
			# Verify if IRQBalancer has the current IRQ Balancer Ban configuration
			grep -q -E "${_IRQBALANCE_ARGS}" /etc/sysconfig/irqbalance
			if [[ "$?" != "0" ]]; then
				# Verify if there aren't any previous old configuration and removing it
				grep -q -E "^IRQBALANCE_ARGS=.*$" /etc/sysconfig/irqbalance
				if [[ "$?" != "0" ]]; then
					sed -e "s/^IRQBALANCE_ARGS=.*$//g" -i /etc/sysconfig/irqbalance
				fi
				# Inject good IRQ Balancer ban configuration
				echo "${_IRQBALANCE_ARGS}" >> /etc/sysconfig/irqbalance
				# Restart IRQ Balancer
				systemctl restart irqbalance.service |& tee -a ${_LOGS}
				# Wait a few seconds
				sleep 5s
				# Do IRQ Affinity
				tuna --irqs=${_IRQLIST} --cpus=${_IRQCORE} --move |& tee -a ${_LOGS}
			fi
		fi

		# Take the KVM Domain PID
		_DOMAINPID=$(ps aux | grep ${_DOMAIN} | grep -v grep | awk '{print $2}')

		# Check if the KVM Domain is on NUMA0 or on NUMA1
		if [[ "$(virsh numatune ${_DOMAIN} | awk '/numa_nodeset/ {print $3}')" == "0" ]]; then
			# Check the QEMU Emulation Threads affinity and don't do anything if it already has the right one
			# Virsh CLI is NOT idempotent.
			if [[ "$(virsh emulatorpin --domain ${_DOMAIN} | grep ${_QEMUCORESNUMA0} | awk '{print $2}')" != "${_QEMUCORESNUMA0}" ]]; then
				echo "### QEMU Emulation Threads affinity on CPU Cores ${_QEMUCORESNUMA0} on NUMA0 for VM ${_NAME}" |& tee -a ${_LOGS}
				virsh emulatorpin --domain ${_DOMAIN} --cpulist ${_QEMUCORESNUMA0} --live |& tee -a ${_LOGS}
			fi

			# The vHost-Net kernel thread has the following format
			# vhost-<KVM Domain main PID>
			# Given this, look for any vHost-Net PID, the output from tuna is already sorted by PID, but do it again
			# Each line represents a specific vHost-Net process, and the current order is the following:
			# 1st and 2nd are BP Network, 3rd is vFAB, 4th is DB and lastly 5th is Ext
			if ${_BPPINNING}; then
				_PIDBP1NUMA0=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 1p)
				_PIDBP2NUMA0=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 2p)
			fi
			_PIDVFAB1NUMA0=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 3p)
			_PIDEXT1NUMA0=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 5p)

			# For each vHost-Net PID, add it to the CGROUP CPU and then change the process scheduling from SCHED_OTHER priority 0 to SCHED_FIFO priority 99
			# The For loop ignore empty variables, if BP Pinning is disabled where will not be any error
			for _VHOSTPID in ${_PIDBP1NUMA0} ${_PIDBP2NUMA0} ${_PIDVFAB1NUMA0} ${_PIDEXT1NUMA0}
			do
				echo "### Set SCHED_FIFO for vHost NET Kernel Threads having PID ${_VHOSTPID} for VM ${_NAME}" |& tee -a ${_LOGS}
				# Both cgclassify and tuna are idempotent.
				cgclassify -g cpu:/ ${_VHOSTPID} |& tee -a ${_LOGS}
				tuna --threads=${_VHOSTPID} --priority=FIFO:99 |& tee -a ${_LOGS}
			done

			# Lastly, do CPU Pinning for each vHost-Net PID as per the static CPU Mapping defined above
			# Taskset is idempotent.
			if ${_BPPINNING}; then
				echo "### CPU Pinning for BP1 on CPU Core ${_PINBP1NUMA0} for VM ${_NAME}" |& tee -a ${_LOGS}
				taskset -pc ${_PINBP1NUMA0} ${_PIDBP1NUMA0} |& tee -a ${_LOGS}
				echo "### CPU Pinning for BP2 on CPU Core ${_PINBP2NUMA0} for VM ${_NAME}" |& tee -a ${_LOGS}
				taskset -pc ${_PINBP2NUMA0} ${_PIDBP2NUMA0} |& tee -a ${_LOGS}
			fi
			echo "### CPU Pinning for vFAB on CPU Core ${_PINVFAB1NUMA0} for VM ${_NAME}" |& tee -a ${_LOGS}
			taskset -pc ${_PINVFAB1NUMA0} ${_PIDVFAB1NUMA0} |& tee -a ${_LOGS}
			echo "### CPU Pinning for EXT on CPU Core ${_PINEXT1NUMA0} for VM ${_NAME}" |& tee -a ${_LOGS}
			taskset -pc ${_PINEXT1NUMA0} ${_PIDEXT1NUMA0} |& tee -a ${_LOGS}
		elif [[ "$(virsh numatune ${_DOMAIN} | awk '/numa_nodeset/ {print $3}')" == "1" ]]; then
			# Do the same on NUMA1 VNF
			if [[ "$(virsh emulatorpin --domain ${_DOMAIN} | grep ${_QEMUCORESNUMA1} | awk '{print $2}')" != "${_QEMUCORESNUMA1}" ]]; then
				# Do general process affinity for all QEMU Emulation Threads
				echo "### QEMU Emulation Threads affinity on CPU Cores ${_QEMUCORESNUMA1} on NUMA1 for VM ${_NAME}" |& tee -a ${_LOGS}
				virsh emulatorpin --domain ${_DOMAIN} --cpulist ${_QEMUCORESNUMA1} --live |& tee -a ${_LOGS}
			fi

			if ${_BPPINNING}; then
				_PIDBP1NUMA1=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 1p)
				_PIDBP2NUMA1=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 2p)
			fi
			_PIDVFAB1NUMA1=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 3p)
			_PIDEXT1NUMA1=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 5p)

			for _VHOSTPID in ${_PIDBP1NUMA1} ${_PIDBP2NUMA1} ${_PIDVFAB1NUMA1} ${_PIDEXT1NUMA1}
			do
				echo "### Set SCHED_FIFO for vHost NET Kernel Threads having PID ${_VHOSTPID} for VM ${_NAME}" |& tee -a ${_LOGS}
				cgclassify -g cpu:/ ${_VHOSTPID}
				tuna --threads=${_VHOSTPID} --priority=FIFO:99
			done

			if ${_BPPINNING}; then
				echo "### CPU Pinning for BP1 on CPU Core ${_PINBP1NUMA1} for VM ${_NAME}" |& tee -a ${_LOGS}
				taskset -pc ${_PINBP1NUMA1} ${_PIDBP1NUMA1}
				echo "### CPU Pinning for BP2 on CPU Core ${_PINBP1NUMA1} for VM ${_NAME}" |& tee -a ${_LOGS}
				taskset -pc ${_PINBP2NUMA1} ${_PIDBP2NUMA1}
			fi
			echo "### CPU Pinning for vFAB on CPU Core ${_PINVFAB1NUMA1} for VM ${_NAME}" |& tee -a ${_LOGS}
			taskset -pc ${_PINVFAB1NUMA1} ${_PIDVFAB1NUMA1}
			echo "### CPU Pinning for EXT on CPU Core ${_PINEXT1NUMA1} for VM ${_NAME}" |& tee -a ${_LOGS}
			taskset -pc ${_PINEXT1NUMA1} ${_PIDEXT1NUMA1}
		fi
	fi
done
echo "### vHost Net Tuning successfully completed at $(date)" |& tee -a ${_LOGS}

# Typical vHOST-NET Allocation
# HEAT HOT Template port allocation
#- port: {get_resource: VSFO-4_BP-1}
#- port: {get_resource: VSFO-4_BP-2}
#- port: {get_resource: VSFO-4_VFAB-1}
#- port: {get_resource: VSFO-4_VFAB-2}
#- port: {get_resource: VSFO-4_DBG}
#- port: {get_resource: VSFO-4_VSFO-4_EXT-1}
#- port: {get_resource: VSFO-4_VSFO-4_EXT-2}
#
# virsh domiflist instance-000016dc
#Interface  Type       Source     Model       MAC
#-------------------------------------------------------
#tap09c79116-eb ethernet   -          virtio      02:00:00:01:04:01 <-- BP-1
#tap49798b60-f7 ethernet   -          virtio      02:00:00:01:04:fe <-- BP-2
#tap9fdcb8b0-61 ethernet   -          virtio      02:00:00:04:04:02 <-- VFAB-1
#tap66a6e1bf-5d ethernet   -          virtio      02:00:00:04:04:03 <-- VFAB-2
#tape8260770-0e ethernet   -          virtio      00:01:00:0a:04:ff <-- DBG
#tapaf28e29f-f3 ethernet   -          virtio      02:af:28:e2:9f:f3 <-- EXT-1
#tap43362406-88 ethernet   -          virtio      02:43:36:24:06:88 <-- EXT-2
#
#Average:      UID       PID    %usr %system  %guest    %CPU   CPU  Command
#Average:        0      6003    0.00    0.08    0.00    0.08     -  vhost-33554 <-- BP-1
#Average:        0      6004    0.00    0.08    0.00    0.08     -  vhost-33554 <-- BP-2
#Average:        0      6005    0.00   18.30    0.00   18.30     -  vhost-33554 <-- VFAB-1
#Average:        0      6006    0.00   17.26    0.00   17.26     -  vhost-33554 <-- VFAB-2
#Average:        0      6007    0.00    0.00    0.00    0.00     -  vhost-33554 <-- DBG
#Average:        0      6008    0.00   34.71    0.00   34.71     -  vhost-33554 <-- EXT-1
#Average:        0      6009    0.00   35.69    0.00   35.69     -  vhost-33554 <-- EXT-2
#
#  6003   OTHER     0 0xf00000f   2329466           17      vhost-5999 <-- BP-1
#  6004   OTHER     0 0xf00000f   1647242            9      vhost-5999 <-- BP-2
#  6005   OTHER     0 0xf00000f  19675949        17210      vhost-5999 <-- VFAB-1
#  6006   OTHER     0 0xf00000f  19079031        17229      vhost-5999 <-- VFAB-2
#  6007   OTHER     0 0xf00000f        63            1      vhost-5999 <-- DBG
#  6008   OTHER     0 0xf00000f  29258258        22495      vhost-5999 <-- EXT-1
#  6009   OTHER     0 0xf00000f  27738633        22738      vhost-5999 <-- EXT-2
