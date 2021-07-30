#!/bin/bash

#VMPREFIX=sample
#MAXVM=4

USERNAME=$(whoami)
echo $USERNAME
SSHKEY=$(echo ${VMPREFIX})
echo $SSHKEY
# 文字列"-pbs" は削除
SSHKEYDIR="$HOME/.ssh/${SSHKEY%-pbs}"
chmod 600 $SSHKEYDIR
echo $SSHKEYDIR
vm1ip=$(cat /home/$USERNAME/nodelist | head -n 1)
echo $vm1ip

# 必要なパッケージ。Ubuntuの場合、以下のパッケージが必要
if   [ -e /etc/debian_version ] || [ -e /etc/debian_release ]; then
    # Check Ubuntu or Debian
    if [ -e /etc/lsb-release ]; then
        # Ubuntu
        echo "ubuntu"
		sudo apt install -qq -y parallel jq curl || apt install -qq -y parallel jq curl
    else
        # Debian
        echo "debian"
		sudo apt install -qq -y parallel jq curl || apt install -qq -y parallel jq curl
	fi
elif [ -e /etc/fedora-release ]; then
    # Fedra
    echo "fedora"
elif [ -e /etc/redhat-release ]; then
	echo "Redhat or CentOS"
	sudo yum install --quiet -y parallel jq curl || yum install -y parallel jq curl
fi

ssh -i $SSHKEYDIR $USERNAME@${vm1ip} -t -t 'sudo showmount -e'
parallel -v -a ./ipaddresslist "ssh -i $SSHKEYDIR $USERNAME@{} -t -t 'df -h | grep 10.0.0.'"
echo "====================================================================================="
parallel -v -a ./ipaddresslist "ssh -i $SSHKEYDIR $USERNAME@{} -t -t 'sudo cat /etc/fstab'"
