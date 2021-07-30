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
seq 1 $MAXVM | parallel -v -a ipaddresslist "ssh -i $SSHKEYDIR azureuser@{} -t -t 'netstat -an | grep -v -e :22 -e 80 -e 443 -e 445'"
