#!/bin/bash

for _IP in $(openstack server list --format value --column Networks --name ctp-compute|sed -e "s/ctlplane=//g");
do
  scp vhost-net-tuning.sh heat-admin@${_IP}:~
  ssh -l heat-admin ${_IP} "sudo su -c 'mv -f /home/heat-admin/vhost-net-tuning.sh /bin/'"
  ssh -l heat-admin ${_IP} "sudo su -c 'chown root:root /bin/vhost-net-tuning.sh'"
  ssh -l heat-admin ${_IP} "sudo su -c 'chmod 0744 /bin/vhost-net-tuning.sh'"
  ssh -l heat-admin ${_IP} "sudo su -c 'echo \"*/1 * * * * root /bin/vhost-net-tuning.sh >> /var/log/vhost-net-tuning_debug.log 2>&1\" > /etc/cron.d/vhost-net-tuning'"
  ssh -l heat-admin ${_IP} "sudo su -c 'systemctl restart crond'"
done
