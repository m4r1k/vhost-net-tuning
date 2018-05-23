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

main()
{

	# Trap for any error during execution
	trap 'err_report $LINENO' ERR

	# Record Starting time
	_DATE=$(date)

	# LOG FILE
	_LOGS="/var/log/vhost-net-tuning.log"
	
	# Check the total number of VMs and exit it if is less than zero
	_DOMAIN=$(virsh list | awk '/running/ {print $2}' | wc -l)
	if (( ${_DOMAIN} == 0 )); then
		echo "No running VNF here." |& tee -a ${_LOGS}
		exit 0
	fi
	
	###### Enable IRQ PINNING ######
	_IRQPINNING=true
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
	###### Enable BP1 and BP2 CPU Pinning ######
	_BPPINNING=true
	###### RegEx for VNF Name ######
	_NAMEPATTERN="^.*VSFO.*$"
	###### RegEx for VNF Project Name ######
	_PROJECTPATTERN="EPC-Ericsson|admin"

	_COMPUTETUNING=false
	
	# For each KVM Domain do the following
	for _DOMAIN in $(virsh list | awk '/running/ {print $2}')
	do
		# Get VM Name and check it against a RegEx
		_NAME=$(virsh dumpxml ${_DOMAIN} | grep nova:name | sed -e 's/<[^>]*>//g' -e 's/  //g')
		_NAMESTATUS=$(echo ${_NAME} | grep -E -q "${_NAMEPATTERN}" && echo true || echo false)

		# Get VM Project Name and check it against a RegEx
		_PROJECT=$(virsh dumpxml ${_DOMAIN} | grep nova:project | sed -e 's/<[^>]*>//g' -e 's/  //g')
		_PROJECTSTATUS=$(echo ${_PROJECT} | grep -E -q "${_PROJECTPATTERN}" && echo true || echo false)

		# If both NAME and PROJECT match the defined criterias go ahead
		if ${_NAMESTATUS} && ${_PROJECTSTATUS}; then

			if ! ${_COMPUTETUNING}; then

				echo "##########" |& tee -a ${_LOGS}
				echo "### vHost Net Tuning initialized at ${_DATE}" |& tee -a ${_LOGS}

				echo "### Started Compute Host Tuning at $(date)" |& tee -a ${_LOGS}

				# Move to function for disable_multiqueue
				disable_multiqueue

				if ${_IRQPINNING}; then
					# Move to function for irq_pinning
					irq_pinning
				fi

				# Move to function for disable_ksm
				disable_ksm

				# Make sure to not re-executure this section of function more then one
				_COMPUTETUNING=true

				echo "### Finished Compute Host Tuning at $(date)" |& tee -a ${_LOGS}
			fi

			echo "### This Compute node has an Ericsson vEPG VM running - ${_NAME}" |& tee -a ${_LOGS}

			# Take the KVM Domain PID
			_DOMAINPID=$(ps aux | grep ${_DOMAIN} | grep -v grep | awk '{print $2}')

			# Check if the KVM Domain is either on NUMA0 or on NUMA1
			_NUMA=$(virsh numatune ${_DOMAIN} | awk '/numa_nodeset/ {print $3}')
			if [[ "${_NUMA}" == "0" ]]; then

				# Move to function for qemu_affinity
				qemu_affinity "${_QEMUCORESNUMA0}" "${_NUMA}"

				# Move to function for vhost_pinning
				vhost_pinning "${_PINBP1NUMA0}" "${_PINBP2NUMA0}" "${_PINVFAB1NUMA0}" "${_PINEXT1NUMA0}"

			elif [[ "${_NUMA}" == "1" ]]; then

				# Move to function for qemu_affinity
				qemu_affinity "${_QEMUCORESNUMA1}" "${_NUMA}"

				# Move to function for vhost_pinning
				vhost_pinning "${_PINBP1NUMA1}" "${_PINBP2NUMA1}" "${_PINVFAB1NUMA1}" "${_PINEXT1NUMA1}"

			fi

			echo "### vHost Net Tuning successfully completed at $(date)" |& tee -a ${_LOGS}
		fi
	done
}

disable_multiqueue()
{

	# Trap for any error during execution
	trap 'err_report $LINENO' ERR

	echo "### Starting Disable MultiQueue at $(date)" |& tee -a ${_LOGS}
	# Disable Multi-Queue for every physical interface member of the bond
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
	done
	echo "### Finished Disable MultiQueue at $(date)" |& tee -a ${_LOGS}
}

irq_pinning()
{

	# Trap for any error during execution
	trap 'err_report $LINENO' ERR

	echo "### Starting IRQ Pinning at $(date)" |& tee -a ${_LOGS}
	_IRQBALANCE_ARGS="IRQBALANCE_ARGS=\""
	_IRQLIST=""
	_BOND=$(vif list --get 0 | awk '/vif0\/0/ {print $3}')
	echo "### Generating IRQ List for any interface in the ${_BOND} LAG" |& tee -a ${_LOGS}
	for _SLAVE in $(cat /sys/class/net/${_BOND}/bonding/slaves);
	do
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
	echo "### Making sure IRQBalancer exclude those IRQ(s) - ${_IRQLIST}" |& tee -a ${_LOGS}
	# Verify if IRQBalancer has the current IRQ Balancer Ban configuration
	if [[ "$(grep -E "^${_IRQBALANCE_ARGS}$" /etc/sysconfig/irqbalance || true)" != "${_IRQBALANCE_ARGS}" ]]; then
		# Remove any previous old configuration 
		sed -e "s/^IRQBALANCE_ARGS=.*$//g" -i /etc/sysconfig/irqbalance || true
		# Inject good IRQ Balancer ban configuration
		echo "${_IRQBALANCE_ARGS}" >> /etc/sysconfig/irqbalance
		# Restart IRQ Balancer
		systemctl restart irqbalance.service |& tee -a ${_LOGS}
		# Wait a few seconds
		sleep 5s
	fi

	IFS=","
	for _SINGLEIRQ in ${_IRQLIST}
	do
		if [[ "$(tuna --show_irqs | awk -v irq=${_SINGLEIRQ} '{if ($1 == irq) {print $3}}')" != "${_IRQCORE}" ]]; then
			echo "### Pinning IRQ ${_SINGLEIRQ} to CPU Core ${_IRQCORE}" |& tee -a ${_LOGS}
			# Do IRQ Affinity
			tuna --irqs=${_SINGLEIRQ} --cpus=${_IRQCORE} --move |& tee -a ${_LOGS}
		fi
	done
	echo "### Finished IRQ Pinning at $(date)" |& tee -a ${_LOGS}
}

disable_ksm()
{

	# Trap for any error during execution
	trap 'err_report $LINENO' ERR

	# Disable KSM in the Compute Node
	echo "### Starting Disable KSM at $(date)" |& tee -a ${_LOGS}
	for _SERVICE in "ksm.service" "ksmtuned.service"
	do
		if [[ "$(/bin/systemctl is-active ${_SERVICE} || true)" != "inactive" ]]; then
			echo "### Disabling ${_SERVICE}" |& tee -a ${_LOGS}
			/bin/systemctl disable ${_SERVICE} |& tee -a ${_LOGS}
			/bin/systemctl stop ${_SERVICE} |& tee -a ${_LOGS}
		else
			echo "### Service ${_SERVICE} already disabled" |& tee -a ${_LOGS}
		fi
	done
	echo "### Finished Disable KSM at $(date)" |& tee -a ${_LOGS}
}

qemu_affinity()
{

	# Trap for any error during execution
	trap 'err_report $LINENO' ERR

	echo "### Starting QEMU EMulation Thread Affinity at $(date)" |& tee -a ${_LOGS}
	_QEMUCORES="$1"
	_NUMA="$2"
	# Check the QEMU Emulation Threads affinity and don't do anything if it already has the right one
	# Virsh CLI is NOT idempotent.
	if [[ "$(virsh emulatorpin --domain ${_DOMAIN} | grep "${_QEMUCORES}" | awk '{print $2}')" != "${_QEMUCORES}" ]]; then
		echo "### QEMU Emulation Threads affinity on CPU Cores ${_QEMUCORES} on NUMA${_NUMA} for VM ${_NAME}" |& tee -a ${_LOGS}
		virsh emulatorpin --domain ${_DOMAIN} --cpulist "${_QEMUCORES}" --live |& tee -a ${_LOGS}
	fi
	echo "### Finished QEMU EMulation Thread Affinity at $(date)" |& tee -a ${_LOGS}
}

vhost_pinning()
{

	# Trap for any error during execution
	trap 'err_report $LINENO' ERR

	echo "### Starting vHost CPU Pinning at $(date)" |& tee -a ${_LOGS}
	_PINBP1="$1"
	_PINBP2="$2"
	_PINVFAB1="$3"
	_PINEXT1="$4"
	# The vHost-Net kernel thread has the following format
	# vhost-<KVM Domain main PID>
	# Given this, look for any vHost-Net PID, the output from tuna is already sorted by PID, but do it again
	# Each line represents a specific vHost-Net process, and the current order is the following:
	# 1st and 2nd are BP Network, 3rd is vFAB, 4th is DB and lastly 5th is Ext
	if ${_BPPINNING}; then
		_PIDBP1=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 1p)
		_PIDBP2=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 2p)
	fi
	_PIDVFAB1=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 3p)
	_PIDEXT1=$(tuna -P | grep vhost-${_DOMAINPID} | awk '{print $1}' | sort -k1n | sed -n 5p)

	# For each vHost-Net PID, add it to the CGROUP CPU and then change the process scheduling from SCHED_OTHER priority 0 to SCHED_FIFO priority 99
	# The For loop ignore empty variables, if BP Pinning is disabled where will not be any error
	for _VHOSTPID in "${_PIDBP1}" "${_PIDBP2}" "${_PIDVFAB1}" "${_PIDEXT1}"
	do
		echo "### Set SCHED_FIFO for vHost NET Kernel Threads having PID ${_VHOSTPID} for VM ${_NAME}" |& tee -a ${_LOGS}
		# Both cgclassify and tuna are idempotent.
		cgclassify -g cpu:/ "${_VHOSTPID}" |& tee -a ${_LOGS}
		tuna --threads="${_VHOSTPID}" --priority=FIFO:99 |& tee -a ${_LOGS}
	done

	# Lastly, do CPU Pinning for each vHost-Net PID as per the static CPU Mapping defined above
	# Taskset is idempotent.
	if ${_BPPINNING}; then
		echo "### CPU Pinning for BP1 on CPU Core ${_PINBP1} for VM ${_NAME}" |& tee -a ${_LOGS}
		taskset -pc "${_PINBP1}" "${_PIDBP1}" |& tee -a ${_LOGS}
		echo "### CPU Pinning for BP2 on CPU Core ${_PINBP2} for VM ${_NAME}" |& tee -a ${_LOGS}
		taskset -pc "${_PINBP2}" "${_PIDBP2}" |& tee -a ${_LOGS}
	fi
	echo "### CPU Pinning for vFAB on CPU Core ${_PINVFAB1} for VM ${_NAME}" |& tee -a ${_LOGS}
	taskset -pc "${_PINVFAB1}" "${_PIDVFAB1}" |& tee -a ${_LOGS}
	echo "### CPU Pinning for EXT on CPU Core ${_PINEXT1} for VM ${_NAME}" |& tee -a ${_LOGS}
	taskset -pc "${_PINEXT1}" "${_PIDEXT1}" |& tee -a ${_LOGS}
	echo "### Finished vHost CPU Pinning at $(date)" |& tee -a ${_LOGS}
}

err_report() {
    echo "ERROR ON LINE $1" |& tee -a ${_LOGS}
    echo "VHOST-NET TUNING TERMINATED!" |& tee -a ${_LOGS}
}

# Trap for any error during execution
trap 'err_report $LINENO' ERR

main "$@"

# Typical vHOST-NET Allocation
# HEAT HOT Template port allocation
#- port: {get_resource: VSFO-4_BP-1}
#- port: {get_resource: VSFO-4_BP-2}
#- port: {get_resource: VSFO-4_VFAB-1}
#- port: {get_resource: VSFO-4_DBG}
#- port: {get_resource: VSFO-4_VSFO-4_EXT-1}
#
# virsh domiflist instance-000016dc
#Interface  Type       Source     Model       MAC
#-------------------------------------------------------
#tap09c79116-eb ethernet   -          virtio      02:00:00:01:04:01 <-- BP-1
#tap49798b60-f7 ethernet   -          virtio      02:00:00:01:04:fe <-- BP-2
#tap9fdcb8b0-61 ethernet   -          virtio      02:00:00:04:04:02 <-- VFAB-1
#tape8260770-0e ethernet   -          virtio      00:01:00:0a:04:ff <-- DBG
#tapaf28e29f-f3 ethernet   -          virtio      02:af:28:e2:9f:f3 <-- EXT-1
#
#Average:      UID       PID    %usr %system  %guest    %CPU   CPU  Command
#Average:        0      6003    0.00    0.08    0.00    0.08     -  vhost-33554 <-- BP-1
#Average:        0      6004    0.00    0.08    0.00    0.08     -  vhost-33554 <-- BP-2
#Average:        0      6005    0.00   18.30    0.00   18.30     -  vhost-33554 <-- VFAB-1
#Average:        0      6006    0.00    0.00    0.00    0.00     -  vhost-33554 <-- DBG
#Average:        0      6007    0.00   34.71    0.00   34.71     -  vhost-33554 <-- EXT-1
#
#  6003   OTHER     0 0xf00000f   2329466           17      vhost-5999 <-- BP-1
#  6004   OTHER     0 0xf00000f   1647242            9      vhost-5999 <-- BP-2
#  6005   OTHER     0 0xf00000f  19675949        17210      vhost-5999 <-- VFAB-1
#  6006   OTHER     0 0xf00000f        63            1      vhost-5999 <-- DBG
#  6007   OTHER     0 0xf00000f  29258258        22495      vhost-5999 <-- EXT-1
