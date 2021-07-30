#!/bin/bash
#VMPREFIX=sample
#USERNAME=sample

# SSH秘密鍵ファイルのディレクトリ決定
tmpfile=$(stat ./${VMPREFIX} -c '%a')
case $tmpfile in
	600 )
		SSHKEYDIR="./${VMPREFIX}"
	;;
	7** )
		cp ./${VMPREFIX} $HOME/.ssh/
		chmod 600 $HOME/.ssh/${VMPREFIX}
		SSHKEYDIR="$HOME/.ssh/${VMPREFIX}"
	;;
esac
echo "SSHKEYDIR: $SSHKEYDIR"
vm1ip=$(sed -n 1P ./ipaddresslist)
ssh -i $SSHKEYDIR $USERNAME@${vm1ip} -t -t 'sudo showmount -e'
parallel -v -a ipaddresslist "ssh -i $SSHKEYDIR $USERNAME@{} -t -t 'df -h | grep 10.0.0.'"
