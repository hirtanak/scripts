$!/usr/bin/bash

VMPREFIX=cfdbmt01
USERNAME=azureuser

rm ./macaddresslist
for count in `seq 1 10`; do
        line=$(sed -n ${count}P ./ipaddresslist)
        ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@$line "echo '================' && hostname && hostname -i"
        ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@$line "/usr/sbin/ifconfig eth0 | awk '/ether/ { print $2 }'"
done
grep -v "Connection to" ./macaddresslist > ./macaddresslist
