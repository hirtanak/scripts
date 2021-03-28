#!/bin/bash

#サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>

#azure_name="uuid"
#azure_password="uuid"
#azure_tenant="uuid"

MyResourceGroup=tmcbmt01
Location=japaneast
VMPREFIX=tmcbmt01
VMSIZE=Standard_D2as_v4 #Standard_HC44rs, Standard_HB120rs_v3
PBSVMSIZE=Standard_D2as_v4

MyAvailabilitySet=${VMPREFIX}avset01
MyNetwork=${VMPREFIX}-vnet01
MySubNetwork=compute
MySubNetwork2=management # ログインノード用
MyNetworkSecurityGroup=${VMPREFIX}-nsg
LIMITEDIP=$(curl -s ifconfig.io)/32 #利用しているクライアントのグローバルIPアドレスを取得
echo "current client global ip address: $LIMITEDIP. This script defines the ristricted access from this client"
LIMITEDIP2=1.1.1.0/24 #追加制限IPアドレスをCIRDで記載 例：1.1.1.0/24
echo "addtional accessible CIDR: $LIMITEDIP2"
# MyNic="cfdbmt-nic"
IMAGE="OpenLogic:CentOS-HPC:7_8:latest"
USERNAME=azureuser
# SSH公開鍵ファイルを指定
SSHKEYFILE="./${VMPREFIX}.pub"
TAG=${VMPREFIX}=$(date "+%Y%m%d")
#
MAXVM=3
# 追加の永続ディスクが必要な場合、ディスクサイズ(GB)を記入する https://azure.microsoft.com/en-us/pricing/details/managed-disks/
PERMANENTDISK=0
PBSPERMANENTDISK=128
# 必要なパッケージ。Ubuntuの場合、以下のパッケージが必要
#sudo apt install -y parallel jq curl
DEBUG="" #"-v"

### コマンド名取得
CMDNAME=`basename $0`

### コマンドオプションエラー処理
if [ $# -ne 1 ]; then
	echo "実行するには1個の引数が必要です。" 1>&2
	echo "create,delete,start,stop,list,remount,pingpong,addlogin 引数を一つ指定する必要があります。" 1>&2
	exit 1
fi

### SSH鍵チェック。なければ作成
if [ ! -f "./${VMPREFIX}" ] || [ ! -f "./${VMPREFIX}.pub" ] ; then
	ssh-keygen -f ./${VMPREFIX} -m pem -t rsa -N "" -b 4096
fi

### ログイン処理
#az login --service-principal --username ${azure_name} --password ${azure_password} --tenant ${azure_tenant} --output none

case $1 in
	create )
		# クリーンナップファイル
		if [ -f ./vmlist ]; then
			rm ./vmlist
		fi
		if [ -f ./ipaddresslist ]; then
			rm ./ipaddresslist
		fi
		### 全体環境作成
		az group create --resource-group $MyResourceGroup --location $Location --tags $TAG --output none
		# ネットワークチェック
		tmpnetwork=$(az network vnet show -g $MyResourceGroup --name $MyNetwork --query id)
		echo "current netowrk id: $tmpnetwork"
		if [ -z "$tmpnetwork" ] ; then
			az network vnet create -g $MyResourceGroup -n $MyNetwork --address-prefix 10.0.0.0/22 --subnet-name $MySubNetwork --subnet-prefix 10.0.0.0/24 --output none
		fi
		az network nsg create --name $MyNetworkSecurityGroup -g $MyResourceGroup -l $Location --tags $TAG --output none
		az network nsg rule create --name ssh --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
		--priority 1000 --source-address-prefix $LIMITEDIP --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
		az network nsg rule create --name ssh2 --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
		--priority 1010 --source-address-prefix $LIMITEDIP2 --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
		# 可用性セット作成。既存のものがあれば利用する
		az vm availability-set create --name $MyAvailabilitySet -g $MyResourceGroup -l $Location --tags $TAG --output none
		numvm=0
		for count in `seq 1 $MAXVM` ; do
			# echo "creating nic # $count"
			# az network nic create --accelerated-networking true --name $MyNic-$count --resource-group $MyResourceGroup --vnet-name $MyNetwork --subnet $MySubNetwork --network-security>
			echo "creating VM # $count"
			az vm create \
				--resource-group $MyResourceGroup --location $Location \
				--name ${VMPREFIX}-${count} \
				--size $VMSIZE --availability-set $MyAvailabilitySet \
				--vnet-name $MyNetwork --subnet $MySubNetwork \
				--nsg $MyNetworkSecurityGroup --nsg-rule SSH \
				--image $IMAGE \
				--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
				--no-wait --tags $TAG -o table &
		done
		while [ $((numvm)) -lt $((MAXVM)) ]; do
			echo "sleep 30" && sleep 30
			az vm list -g $MyResourceGroup | jq '.[] | .name' | grep ${VMPREFIX} > ./vmlist
			numvm=$(cat ./vmlist | wc -l)
		done
		echo "careated VM list" && echo "$(cat ./vmlist)"
		for count in $(seq 1 $MAXVM) ; do
			echo "VM $count: ${VMPREFIX}-$count"
			unset ipaddresstmp
			while [ -z $ipaddresstmp ]; do
				ipaddresstmp=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-${count} --query publicIps -o tsv)
				echo "ip: $ipaddresstmp"
			done
			echo $ipaddresstmp >> ipaddresslist
		done
		echo "ipaddresslist file contents"
		cat ./ipaddresslist
		# 永続ディスクが必要な場合に設定可能
		if [ $((PERMANENTDISK)) -gt 0 ]; then
			az vm disk attach --new -g $MyResourceGroup --size-gb $PERMANENTDISK --sku Premium_LRS --vm-name ${VMPREFIX}-1 --name ${VMPREFIX}-1-disk0 -o table
		fi
		echo "setting up nfs server"
		vm1ip=$(cat ./ipaddresslist | head -n 1)
		tmpfile=$(stat ./${VMPREFIX} -c '%a')
		case $tmpfile in
			600 )
				for count in `seq 1 3`; do
					checkssh=$(ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t $USERNAME@${vm1ip} "uname")
					echo "waiting sshd @ ${VMPREFIX}-1: sleep 10" && sleep 10
				done
			;;
			7** )
				for count in `seq 1 3`; do
					checkssh=$(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t $USERNAME@${vm1ip} "uname")
					echo "waiting sshd @ ${VMPREFIX}-1: sleep 10" && sleep 10
				done
			;;
		esac
		echo "checkssh connectiblity for ${VMPREFIX}-1: $checkssh"
		if [ -z $checkssh ]; then
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript \
				--scripts "sudo yum install -y nfs-utils && echo '/mnt/resource *(rw,no_root_squash,async)' >> /etc/exports"
			sleep 5
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo chown ${USERNAME}:${USERNAME} /mnt/resource"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo systemctl start rpcbind && sudo systemctl start nfs"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo systemctl enable rpcbind && sudo systemctl enable nfs"
		else
			# SSH設定が高速
			tmpfile=$(stat ./${VMPREFIX} -c '%a')
			case $tmpfile in
			600 )
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "sudo yum install -y nfs-utils"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "echo '/mnt/resource *(rw,no_root_squash,async)' | sudo tee /etc/exports"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "sudo chown ${USERNAME}:${USERNAME} /mnt/resource"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "sudo systemctl start rpcbind && sudo systemctl start nfs"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "sudo systemctl enable rpcbind && sudo systemctl enable nfs"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "sudo showmount -e"
			;;
			7** )
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "sudo yum install -y nfs-utils"
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "echo '/mnt/resource *(rw,no_root_squash,async)' | sudo tee /etc/exports"
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "sudo chown ${USERNAME}:${USERNAME} /mnt/resource"
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "sudo systemctl start rpcbind && sudo systemctl start nfs"
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "sudo systemctl enable rpcbind && sudo systemctl enable nfs"
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t $USERNAME@${vm1ip} -t -t "sudo showmount -e"
			;;
		esac
		fi
		echo "setting up nfs client"
		mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -otsv)
		echo "mountip: $mountip"
		# 高速化のために一回実施しておく
		case $tmpfile in
			600 )
			echo "600: ssh parallel settings: nfs client"
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo yum install --quiet -y nfs-utils""
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo mkdir -p /mnt/resource"
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource"
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource""
			;;
			7** )
			echo "700: ssh parallel settings: nfs client"
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo yum install --quiet -y nfs-utils""
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo mkdir -p /mnt/resource"
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource"
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource""
			;;
		esac
		count=2
		for count in `seq 2 $MAXVM` ; do
			line=$(sed -n ${count}P ./ipaddresslist)
			case $tmpfile in
				600 )
					for cnt in `seq 1 3`; do
						checkssh=$(ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${line} -t -t "uname")
						echo "waiting sshd @ ${VMPREFIX}-${count}: $checkssh sleep 10" && sleep 10
					done
				if [ ! -z $checkssh ]; then
					echo "600: setting by ssh command"
					ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${line} -t -t "sudo yum install -y nfs-utils"
					ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${line} -t -t "sudo mkdir -p /mnt/resource"
					ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${line} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource"
					ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${line} -t -t "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource"
					ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${line} -t -t "echo '/dev/sdb1    /mnt/resource    xfs    defaults    0    2' | sudo tee /etc/fstab"
				else
					echo "600: setting by az vm run-command"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts 'sudo yum install -y nfs-utils'
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mkdir -p /mnt/resource"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo chown $USERNAME:$USERNAME /mnt/resource"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript \
						--scripts "echo '/dev/sdb1    /mnt/resource    xfs    defaults    0    2' | sudo tee /etc/fstab"
				fi
				;;
				7** )
					for cnt in `seq 1 3`; do
						checkssh=$(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${line} -t -t "uname")
						echo "waiting sshd @ ${VMPREFIX}-${count}: $checkssh sleep 10" && sleep 10
					done
				if [ ! -z $checkssh ]; then
					echo "700: setting by ssh command"
					ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${line} -t -t "sudo yum install -y nfs-utils"
					ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${line} -t -t "sudo mkdir -p /mnt/resource"
					ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${line} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource"
					ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${line} -t -t "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource"
					ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${line} -t -t "echo '/dev/sdb1    /mnt/resource    xfs    defaults    0    2' | sudo tee /etc/fstab"
				else
					echo "700: setting by az vm run-command"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts 'sudo yum install -y nfs-utils'
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mkdir -p /mnt/resource"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo chown $USERNAME:$USERNAME /mnt/resource"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript \
						--scripts "echo '/dev/sdb1    /mnt/resource    xfs    defaults    0    2' | sudo tee /etc/fstab"
				fi
				;;
			esac
		done
		# SSHパスワードレスセッティング
		echo "preparing for passwordless settings"
		cat ./ipaddresslist
		# SSH追加設定
		if [ -f ./config ]; then
			rm ./config
		fi
cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
		tmpfile=$(stat ./${VMPREFIX} -c '%a')
		case $tmpfile in
			600 )
				echo "600: configuring passwordless settings"
				parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} ./${VMPREFIX} $USERNAME@{}:/home/$USERNAME/.ssh/${VMPREFIX}"
				parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} ./${VMPREFIX} $USERNAME@{}:/home/$USERNAME/.ssh/id_rsa"
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@{} -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa""
				parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} ./${VMPREFIX}.pub $USERNAME@{}:/home/$USERNAME/.ssh/${VMPREFIX}.pub"
				# SSH追加設定
				for count in `seq 1 $MAXVM` ; do
					line=$(sed -n ${count}P ./ipaddresslist)
					scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} ./config $USERNAME@${line}:/home/$USERNAME/.ssh/config
					ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${line} -t -t "chmod 600 /home/$USERNAME/.ssh/config"
				done
			;;
			7** )
				# 何らかの事情でファイルパーミッションが設定できていない場合、~/.ssh/ディレクトリを利用する
				cp ./${VMPREFIX} ~/.ssh/
				chmod 600 ~/.ssh/${VMPREFIX}
				echo "700: configuring passwordless settings"
				parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} ./${VMPREFIX} $USERNAME@{}:/home/$USERNAME/.ssh/${VMPREFIX}"
				parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} ./${VMPREFIX} $USERNAME@{}:/home/$USERNAME/.ssh/id_rsa"
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa""
				parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} ./${VMPREFIX}.pub $USERNAME@{}:/home/$USERNAME/.ssh/${VMPREFIX}.pub"
				# SSH追加設定
				for count in `seq 1 $MAXVM` ; do
					line=$(sed -n ${count}P ./ipaddresslist)
					scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} ./config $USERNAME@${line}:/home/$USERNAME/.ssh/config
					ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${line} -t -t "chmod 600 /home/$USERNAME/.ssh/config"
				done
			;;
		esac
	;;
	start )
    ## OSディスクタイプ変更: Premium_LRS
		azure_sku2="Premium_LRS"
		osdiskid=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs --query storageProfile.osDisk.managedDisk.id -o tsv)
		az disk update --sku ${azure_sku2} --ids ${osdiskid}
		## Dataディスクタイプ変更: Premium_LRS
		az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs --query storageProfile.dataDisks[*].managedDisk -o tsv \
		| awk -F" " '{ print $2}' | xargs -I{} az disk update --sku ${azure_sku2} --ids {}
		echo "starting PBS VM"
		az vm start -g $MyResourceGroup --name ${VMPREFIX}-pbs --output none
		echo "starting loging VM"
		az vm start -g $MyResourceGroup --name ${VMPREFIX}-login --output none
		echo "starting VM ${VMPREFIX}-1"
		az vm start -g $MyResourceGroup --name ${VMPREFIX}-1 --output none
		echo "starting VM ${VMPREFIX}:2-$MAXVM compute nodes"
		seq 2 $MAXVM | parallel "az vm start -g $MyResourceGroup --name ${VMPREFIX}-{} --output none"
		echo "checking VM status"
		numvm=0
		while [ $((numvm)) -lt $((MAXVM)) ]; do
			tmpnumvm=$(az vm list -d --query "[?powerState=='VM running']" -o tsv)
			echo $tmpnumvm | tr ' ' '\n' > ./tmpnumvm.txt
			numvm=$(grep -c "running" ./tmpnumvm.txt)
			echo "current running VMs: $numvm"
			sleep 5
		done
		rm ./tmpnumvm.txt
		# ダイナミックの場合（デフォルト）、再度IPアドレスリストを作成しなおす
		if [ -f ./ipaddresslist ]; then
			rm ./ipaddresslist
		fi
		for count in $(seq 1 $MAXVM) ; do
			echo "VM $count: ${VMPREFIX}-$count"
			unset ipaddresstmp
			while [ -z $ipaddresstmp ]; do
				ipaddresstmp=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-${count} --query publicIps -o tsv)
				echo "ip: $ipaddresstmp"
			done
			echo $ipaddresstmp >> ipaddresslist
		done
		echo "current ip address list"
		cat ./ipaddresslist
		echo "nfs server @ ${VMPREFIX}-1"
		vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-${count} --query publicIps -o tsv)
		echo "${VMPREFIX}-1's IP: $vm1ip"
		mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -o tsv)
		# マウント設定
		tmpfile=$(stat ./${VMPREFIX} -c '%a')
		# インターネットからアクセス可能であれば、SSHで高速に設定する
		if [ -z $vm1ip ]; then
		# vm1ipが空なら、IPアドレスが取得できなければ、az cliでの取得
			for count in $(seq 2 $MAXVM) ; do
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource"
			done
		fi
		if [ ! -z $vm1ip ]; then
			# vm1ipが空でなければSSHの取得
			case $tmpfile in
				600 )
					echo "600:${VMPREFIX}-1: $vm1ip"
					ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${ipaddresstmp} 'sudo showmount -e'
					echo "600:mounting: ${VMPREFIX}: 2-$MAXVM"
					parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo mkdir -p /mnt/resource""
					parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource""
					parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource""
				;;
				7** )
					# 何らかの事情でファイルパーミッションが設定できていない場合、~/.ssh/ディレクトリを利用する
					cp ./${VMPREFIX} ~/.ssh/
					chmod 600 ~/.ssh/${VMPREFIX}
					echo "700:${VMPREFIX}-1: $vm1ip"
					ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${ipaddresstmp} 'sudo showmount -e'
					echo "700:mounting: ${VMPREFIX}: 2-$MAXVM"
					parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo mkdir -p /mnt/resource""
					parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource""
					parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource""
				####		rm ./tmpnumvm.txt
				;;
			esac
		fi
	;;
	stop )
		for count in $(seq 1 $MAXVM) ; do
			echo "stoping VM $count"
			az vm stop -g $MyResourceGroup --name ${VMPREFIX}-${count} &
		done
	;;
	stop-all )
		for count in $(seq 1 $MAXVM) ; do
			echo "stoping VM $count"
			az vm stop -g $MyResourceGroup --name ${VMPREFIX}-${count} &
		done
		echo "stoping PBS VM"
		az vm stop -g $MyResourceGroup --name ${VMPREFIX}-pbs &
		echo "stoping login VM"
		az vm stop -g $MyResourceGroup --name ${VMPREFIX}-login &
		## OSディスクタイプ変更: Standard_LRS
		azure_sku1="Standard_LRS"
##		osdiskid=$(az vm show -g ${azure_rg} --name ${azure_vmname1} --query storageProfile.osDisk.managedDisk.id -o tsv)
		echo "converting computing node OS disk"
		parallel -v -a ./tmposdiskidlist "az disk update --sku ${azure_sku1} --ids {}"
		## Dataディスクタイプ変更: Standard_LRS
		echo "converting PBS node data disk"
		az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs --query storageProfile.dataDisks[*].managedDisk -o tsv | awk -F" " '{ print $2}' | xargs -I{} az disk update --sku ${azure_sku1} --ids {}
		echo "converting compute node #1 data disk"
		az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 --query storageProfile.dataDisks[*].managedDisk -o tsv | awk -F" " '{ print $2}' | xargs -I{} az disk update --sku ${azure_sku1} --ids {}
	;;
	list )
		echo "listng running(/stop) VM"
		az vm list -g $MyResourceGroup -d -o table
		echo "nfs server status"
		vm1state=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query powerState)
		if [ ! "$vm1state"="VM running" ]; then
			echo "VM #1 is not running"
			exit 1
		fi
		vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
		ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${vm1ip} 'sudo showmount -e'
		echo "current mounting status"
		count=0
		for count in `seq 2 $MAXVM`; do
			line=$(sed -n ${count}P ./ipaddresslist)
			ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@${line} "echo "########## host: ${VMPREFIX}-${count} ##########""
			ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@${line} "df | grep '/mnt/resource'"
		done
	;;
	delete )
		if [ -f ./tmposdiskidlist ]; then
			rm ./tmposdiskidlist
		fi
		for count in $(seq 1 $MAXVM) ; do
			disktmp=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-${count} --query storageProfile.osDisk.managedDisk.id -o tsv)
			echo $disktmp >> tmposdiskidlist
		done
		echo "deleting compute VMs"
		seq 1 $MAXVM | parallel "az vm delete -g $MyResourceGroup --name ${VMPREFIX}-{} --yes &"
		numvm=$(cat ./vmlist | wc -l)
		while [ $((numvm)) -gt 0 ]; do
			echo "sleep 30" && sleep 30
			echo "current running VMs: $numvm"
			az vm list -g $MyResourceGroup | jq '.[] | .name' | grep ${VMPREFIX} > ./vmlist
		numvm=$(cat ./vmlist | wc -l)
		done
		echo "deleting disk"
		parallel -a tmposdiskidlist "az disk delete --ids {} --yes"
		sleep 10
		echo "deleting nic"
		seq 1 $MAXVM | parallel "az network nic delete -g $MyResourceGroup --name ${VMPREFIX}-{}VMNic"
		echo "deleting public ip"
		seq 1 $MAXVM | parallel "az network public-ip delete -g $MyResourceGroup --name ${VMPREFIX}-{}PublicIP"
		echo "detele data disk"
		az disk delete -g $MyResourceGroup --name ${VMPREFIX}-1-disk0 --yes
		echo "current running VMs: ${numvm}"
		# ファイル削除
		rm ./ipaddresslist
		rm ./tmposdiskidlist
		rm ./vmlist
	;;
	delete-all )
		if [ -f ./tmposdiskidlist ]; then
			rm ./tmposdiskidlist
		fi
		for count in $(seq 1 $MAXVM) ; do
			disktmp=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-${count} --query storageProfile.osDisk.managedDisk.id -o tsv)
			echo $disktmp >> tmposdiskidlist
		done
		disktmp=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs --query storageProfile.osDisk.managedDisk.id -o tsv)
		echo $disktmp >> tmposdiskidlist
		disktmp=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-login --query storageProfile.osDisk.managedDisk.id -o tsv)
		echo $disktmp >> tmposdiskidlist
		echo "deleting compute VMs"
		seq 1 $MAXVM | parallel "az vm delete -g $MyResourceGroup --name ${VMPREFIX}-{} --yes &"
		echo "deleting pbs node"
		az vm delete -g $MyResourceGroup --name ${VMPREFIX}-pbs --yes &
		echo "deleting login node"
		az vm delete -g $MyResourceGroup --name ${VMPREFIX}-login --yes &
		numvm=$(cat ./vmlist | wc -l)
		while [ $((numvm)) -gt 0 ]; do
			echo "sleep 30" && sleep 30
			echo "current running VMs: $numvm"
			az vm list -g $MyResourceGroup | jq '.[] | .name' | grep ${VMPREFIX} > ./vmlist
			numvm=$(cat ./vmlist | wc -l)
		done
		echo "deleting disk"
		parallel -a tmposdiskidlist "az disk delete --ids {} --yes"
		sleep 10
		echo "deleting nic"
		seq 1 $MAXVM | parallel "az network nic delete -g $MyResourceGroup --name ${VMPREFIX}-{}VMNic"
		az network nic delete -g $MyResourceGroup --name ${VMPREFIX}-pbsVMNic
		az network nic delete -g $MyResourceGroup --name ${VMPREFIX}-loginVMNic
		echo "deleting public ip"
		seq 1 $MAXVM | parallel "az network public-ip delete -g $MyResourceGroup --name ${VMPREFIX}-{}PublicIP"
		az network public-ip delete -g $MyResourceGroup --name ${VMPREFIX}-pbsPublicIP
		az network public-ip delete -g $MyResourceGroup --name ${VMPREFIX}-loginPublicIP
		echo "detele data disk"
		az disk delete -g $MyResourceGroup --name ${VMPREFIX}-1-disk0 --yes
		az disk delete -g $MyResourceGroup --name ${VMPREFIX}-pbs-disk0 --yes
		echo "current running VMs: ${numvm}"
		# ファイル削除
		rm ./ipaddresslist
		rm ./tmposdiskidlist
		rm ./vmlist
	;;
	remount )
		# mounting nfs server from compute node.
		numvm=$(cat ./ipaddresslist | wc -l)
		if [ -f ./ipaddresslist ]; then
			# コマンド実行判断
			vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
#			|\\\|\\\|\\\vm1ip=$(head -1 ./ipaddresslist)
			echo "${VMPREFIX}-1's IP: $ipaddresstmp"
			mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -otsv)
			pbsmountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs -d --query privateIps -otsv)
			tmpfile=$(stat ./${VMPREFIX} -c '%a')
			case $tmpfile in
				600 )
					echo "current mounting status"
					parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "df | grep '/mnt/resource'""
					echo "600:${VMPREFIX}-1: $vm1ip"
					ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${ipaddresstmp} 'sudo showmount -e'
					echo "600:mounting: ${VMPREFIX}: 2-$MAXVM"
					parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo mkdir -p /mnt/resource""
					parallel $DEUBG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME /mnt/resource""
					parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:/mnt/resource /mnt/resource""
					if [ ! -z "$pbsmountip" ]; then
						parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo mkdir -p /mnt/share""
						parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME /mnt/share""
						parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:/mnt/share""
					fi
				;;
				7** )
					echo "current mounting status"
					parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "df | grep '/mnt/resource'""
					echo "700:${VMPREFIX}-1: $vm1ip"
					ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${ipaddresstmp} 'showmount -e'
					echo "700:mounting: ${VMPREFIX}: 2-$MAXVM"
					parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo mkdir -p /mnt/resource""
					parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME /mnt/resource""
					parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:/mnt/resource /mnt/resource""
					if [ ! -z "$pbsmountip" ]; then
						parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo mkdir -p /mnt/share""
						parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME /mnt/resource""
						parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:/mnt/share""
					fi
				;;
			esac
		else
			for count in $(seq 2 $MAXVM) ; do
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "mount -t nfs ${mountip}:/mnt/resource /mnt/resource" &
			done
			echo "sleep 180" && sleep 180
			for count in $(seq 2 $MAXVM) ; do
				if [ ! -z "$pbsmountip" ]; then
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "mount -t nfs ${pbdmountip}:/mnt/share /mnt/share" &
					sleep 10
				fi
			done
		fi
	;;
	pingpong )
		# コマンド実行判断
		vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-${count} --query publicIps -o tsv)
		if [ -z $vm1ip ]; then
			echo "pingpong function required internet access from this client"
			exit 1
		fi
		# 初期設定：ファイル削除、ホストファイル作成
		if [ -f ./nodelist ]; then
			rm ./nodelist
		fi
		for count in $(seq 1 $MAXVM) ; do
			nodelist=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-${count} -d --query privateIps -o tsv)
			echo $nodelist >> nodelist
		done
		if [ -f ./pingponglist ]; then
			rm ./pingponglist
		fi
		# ノードファイル作成
		for NODE in `cat ./nodelist`; do
			for NODE2 in `cat ./nodelist`; do
				echo "$NODE,$NODE2" >> pingponglist
			done
		done
		# fullpingpongコマンドスクリプト作成
		rm ./fullpingpong.sh
		cat <<'EOL' >> fullpingpong.sh
#!/bin/bash
IMPI_VERSION=2018.4.274
cp /home/$USER/* /mnt/resource/
cd /mnt/resource/
count=1
max=$(cat ./pingponglist | wc -l)
echo max: $max
# run pingpong
case $IMPI_VERSION in
	2018* )
		for count in `seq 1 $max`; do
			line=$(sed -n ${count}P ./pingponglist)
			echo "############### ${line} ###############" >> result
			/opt/intel/impi/${IMPI_VERSION}/intel64/bin/mpirun -hosts $line -ppn 1 -n 2 -env I_MPI_FABRICS=shm:ofa /opt/intel/impi/${IMPI_VERSION}/bin64/IMB-MPI1 pingpong >> result
		done
	;;
esac
EOL
# ヒアドキュメントのルール上改行不可
		rm ./config
cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
		# fullpingpon実行
		echo "pingponglist: $pingponglist"
		vm1ip=$(head -1 ./ipaddresslist)
		impidir=$(ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${vm1ip} "ls /opt/intel/impi/")
		cat ./pingponglist
		scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./fullpingpong.sh $USERNAME${vm1ip}:/home/$USERNAME/
		scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./pingponglist $USERNAME@${vm1ip}:/home/$USERNAME/
		scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./fullpingpong.sh $USERNAME@${vm1ip}:/mnt/resource/
		scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./pingponglist $USERNAME@${vm1ip}:/mnt/resource/
		# SSH追加設定
		tmpfile=$(stat ./${VMPREFIX} -c '%a')
		cat ./ipaddresslist
		case $tmpfile in
			600 )
				echo "600: copy passwordless settings"
				seq 1 $MAXVM | parallel -v -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./config $USERNAME@{}:/home/$USERNAME/.ssh/config"
				seq 1 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} -t -t "chmod 600 /home/$USERNAME/.ssh/config""
			;;
			7** )
				echo "700: copy passwordless settings"
				seq 1 $MAXVM | parallel -v -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./config $USERNAME/@{}:/home/$USERNAME/.ssh/config"
				seq 1 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} -t -t "chmod 600 /home/$USERNAME/.ssh/config""
			;;
		esac
		# コマンド実行
		ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${vm1ip} -t -t "rm /mnt/resource/result"
		ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${vm1ip} -t -t "bash /mnt/resource/fullpingpong.sh > /mnt/resource/result"
		sleep 60
		scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} azureuser@$vm1ip:/mnt/resource/result ./
	;;
	addlogin )
		# ネットワークチェック
		tmpsubnetwork=$(az network vnet subnet show -g $MyResourceGroup --name $MySubNetwork2 --vnet-name $MyNetwork --query id)
		echo "current subnetowrk id: $tmpsubnetwork"
		if [ -z ]; then
			# サブネット追加
			az network vnet subnet create -g $MyResourceGroup --vnet-name $MyNetwork -n $MySubNetwork2 --address-prefixes 10.0.1.0/24 --network-security-group $MyNetworkSecurityGroup -o table
		fi
		# ログインノード作成
		echo "creating login node"
		az vm create \
			--resource-group $MyResourceGroup --location $Location \
			--name ${VMPREFIX}-login \
			--size Standard_D2a_v4 \
			--vnet-name $MyNetwork --subnet $MySubNetwork2 \
			--nsg $MyNetworkSecurityGroup --nsg-rule SSH \
			--image $IMAGE \
			--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
			--tags $TAG -o table
		# PBSジョブスケジューラノード作成
		echo "creatig PBS node"
		az vm create \
			--resource-group $MyResourceGroup --location $Location \
			--name ${VMPREFIX}-pbs \
			--size $PBSVMSIZE \
			--vnet-name $MyNetwork --subnet $MySubNetwork \
			--nsg $MyNetworkSecurityGroup --nsg-rule SSH \
			--image $IMAGE \
			--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
			--tags $TAG -o table
		# PBSノードIPアドレス取得
		pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
		# 永続ディスクが必要な場合に設定可能
		if [ $((PBSPERMANENTDISK)) -gt 0 ]; then
			az vm disk attach --new -g $MyResourceGroup --size-gb $PBSPERMANENTDISK --sku Premium_LRS --vm-name ${VMPREFIX}-pbs --name ${VMPREFIX}-pbs-disk0 -o table
		fi
		# SSHパスワードレスセッティング
		echo "pbsnode: prparing passwordless settings"
		# ない場合にのみ、SSH config設定作成
		if [ ! -f ./config ]; then
		cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
		fi
		tmpfile=$(stat ./${VMPREFIX} -c '%a')
		case $tmpfile in
			600 )
			echo "600: pbsnode: confugring passwordless settings"
			scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./${VMPREFIX} $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/${VMPREFIX}
			scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./${VMPREFIX} $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/id_rsa
			ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
			scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./${VMPREFIX}.pub $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/${VMPREFIX}.pub
			# SSH Config設定
			scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./config $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/config
			ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "chmod 600 /home/$USERNAME/.ssh/config"
		;;
			7** )
				# 何らかの事情でファイルパーミッションが設定できていない場合、~/.ssh/ディレクトリを利用する
				cp ./${VMPREFIX} ~/.ssh/
				chmod 600 ~/.ssh/${VMPREFIX}
				echo "700: bsnode: confugring passwordless settings"
				scp -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} ./${VMPREFIX} $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/${VMPREFIX}
				scp -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} ./${VMPREFIX} $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/id_rsa
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
				scp -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX}  ./${VMPREFIX}.pub $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/${VMPREFIX}.pub
				# SSH Config設定
				scp -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} ./config $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/config
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "chmod 600 /home/$USERNAME/.ssh/config"
			;;
		esac
		# ディスクフォーマット
#		tmpfile=$(stat ./${VMPREFIX} -c '%a')
		case $tmpfile in
			600 )
				echo "600: disk formatting"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo parted /dev/sdc --script mklabel gpt mkpart xfspart xfs 0% 100%"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo mkfs.xfs /dev/sdc1"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo partprobe /dev/sdc1"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo mkdir -p /mnt/share"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo mount $DEBUG /dev/sdc1 /mnt/share"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo chown $USERNAME:$USERNAME /mnt/share"
				ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo systemctl restart rpcbind && sudo systemctl restart nfs"
			;;
			7** )
				echo "700: disk formatting"
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo parted /dev/sdc --script mklabel gpt mkpart xfspart xfs 0% 100%"
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo mkfs.xfs /dev/sdc1"
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo partprobe /dev/sdc1"
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo mkdir -p /mnt/share"
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo mount $DEBUG /dev/sdc1 /mnt/share"
				ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo chown $USERNAME:$USERNAME /mnt/share"
			;;
		esac
		# PBS
		pbsmountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs -d --query privateIps -otsv)
		case $tmpfile in
			600 )
				echo "600: mouting new directry on PBS node: /mnt/share"
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo mkdir -p /mnt/share"
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo $USERNAME:$USERNAME /mnt/share"
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo mount $DEBUG -t nfs ${pbsmountip}:/mnt/share /mnt/share""
			;;
			7** )
				echo "700: mouting new directry on PBS node: /mnt/share"
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo mkdir -p /mnt/share"
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo $USERNAME:$USERNAME /mnt/share"
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo mount $DEBUG -t nfs ${pbsmountip}:/mnt/share /mnt/share""
			;;
		esac
		# PBSインストール準備
#		pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
		baseurl=https://github.com/hirtanak/scripts/blob/master
		wget -q $baseurl/openpbs-server-20.0.1-0.x86_64.rpm -O ./openpbs-server-20.0.1-0.x86_64.rpm
		wget -q $baseurl/openpbs-execution-20.0.1-0.x86_64.rpm -O ./openpbs-execution-20.0.1-0.x86_64.rpm
		wget -q $baseurl/openpbs-client-20.0.1-0.x86_64.rpm -I ./openpbs-client-20.0.1-0.x86_64.rpm
		if [ ! -f ./openpbs-server-20.0.1-0.x86_64.rpm ] || [ ! -f ./openpbs-client-20.0.1-0.x86_64.rpm ] || [ ! -f ./openpbs-execution-20.0.1-0.x86_64.rpm ]; then
			echo "file download error!. please download manually OpenPBS file in current diretory"
		fi
		# OpenPBS serverコピー
		tmpfile=$(stat ./${VMPREFIX} -c '%a')
		case $tmpfile in
			600 )
				echo "copy openpbs-server-20.0.1-0.x86_64.rpm"
				scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} ./openpbs-server-20.0.1-0.x86_64.rpm $USERNAME@${pbsvmip}:/home/$USERNAME/
				scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} ./openpbs-client-20.0.1-0.x86_64.rpm $USERNAME@${pbsvmip}:/home/$USERNAME/
				# openPBS requirement
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo yum install -y expat libedit postgresql-server postgresql-contrib python3 sendmail sudo tcl tk libical"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo yum install hwloc-libs libICE libSM"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo rpm -ivh openpbs-server-20.0.1-0.x86_64.rpm"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo rpm -ivh openpbs-client-20.0.1-0.x86_64.rpm"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo /opt/pbs/libexec/pbs_postinstall"
				# configure /etc/pbs.conf file
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo sed -e 's/PBS_START_SERVER=0/PBS_START_SERVER=1/g' /etc/pbs.conf"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo sed -e 's/PBS_START_SCHED=0/PBS_START_SCHED=1/g' /etc/pbs.conf"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo sed -e 's/PBS_START_COMM=0/PBS_START_COMM=1/g' /etc/pbs.conf"
				# change permission
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "chmod 4755 /opt/pbs/sbin/pbs_iff"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "chmod 4755 /opt/pbs/sbin/pbs_rcp"

			;;
			7** )
				echo "copy openpbs-server-20.0.1-0.x86_64.rpm"
				scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} ./openpbs-server-20.0.1-0.x86_64.rpm $USERNAME@${pbsvmip}:/home/$USERNAME/
				scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} ./openpbs-client-20.0.1-0.x86_64.rpm $USERNAME@${pbsvmip}:/home/$USERNAME/
				# openPBS requirement
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo yum install -y expat libedit postgresql-server postgresql-contrib python3 sendmail sudo tcl tk libical"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo yum install hwloc-libs libICE libSM"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo rpm -ivh openpbs-server-20.0.1-0.x86_64.rpm"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo rpm -ivh openpbs-client-20.0.1-0.x86_64.rpm"
				# configure /etc/pbs.conf file
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo /opt/pbs/libexec/pbs_postinstall"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo sed -e 's/PBS_START_SERVER=0/PBS_START_SERVER=1/g' /etc/pbs.conf"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo sed -e 's/PBS_START_SCHED=0/PBS_START_SCHED=1/g' /etc/pbs.conf"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "sudo sed -e 's/PBS_START_COMM=0/PBS_START_COMM=1/g' /etc/pbs.conf"
				# change permission
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "chmod 4755 /opt/pbs/sbin/pbs_iff"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "chmod 4755 /opt/pbs/sbin/pbs_rcp"
			;;
		esac
		# OpenPBS clientコピー
#		tmpfile=$(stat ./${VMPREFIX} -c '%a')
		case $tmpfile in
			600 )
				echo "copy openpbs-execution-20.0.1-0.x86_64.rpm to all compute nodes"
				parallel -v -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
				parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo yum install hwloc-libs libICE libSM""
				parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo rpm -ivh openpbs-client-20.0.1-0.x86_64.rpm"
				parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo /opt/pbs/libexec/pbs_postinstall"
				parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@{} -t -t "sudo sed -e 's/PBS_START_MOM=0/PBS_START_MOM=1/g' /etc/pbs.conf"
			;;
			7** )
				# 何らかの事情でファイルパーミッションが設定できていない場合、~/.ssh/ディレクトリを利用する
				cp ./${VMPREFIX} ~/.ssh/
				chmod 600 ~/.ssh/${VMPREFIX}
				echo "copy openpbs-execution-20.0.1-0.x86_64.rpm to all compute nodes"
				parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX}  ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo yum install hwloc-libs libICE libSM""
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo rpm -ivh openpbs-client-20.0.1-0.x86_64.rpm""
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo /opt/pbs/libexec/pbs_postinstall""
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "sudo sed -e 's/PBS_START_MOM=0/PBS_START_MOM=1/g' /etc/pbs.conf"
			;;
		esac
		# ddddd
#|\\|\\\tmpfile=$(stat ./${VMPREFIX} -c '%a')
		case $tmpfile in
			600 )
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "/etc/init.d/pbs start"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@${pbsvmip} -t -t "echo 'source /etc/profile.d/pbs.sh' >> ~/.bashrc"
				#
				parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@{} -t -t "/etc/init.d/pbs start"
				parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ./${VMPREFIX} $USERNAME@{} -t -t "echo 'source /etc/profile.d/pbs.sh' >> ~/.bashrc"

			;;
			7** )
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "/etc/init.d/pbs start"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@${pbsvmip} -t -t "cho 'source /etc/profile.d/pbs.sh' >> ~/.bashrc"
				#
				parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "/etc/init.d/pbs start"
				parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ~/.ssh/${VMPREFIX} $USERNAME@{} -t -t "echo 'source /etc/profile.d/pbs.sh' >> ~/.bashrc"
			;;
		esac
		echo "finished to set up additonal login and PBS node"
	;;
	private )
		# 既存のクラスターからインターネットからの外部接続を削除する
		count=0
		for count in `seq 1 $MAXVM`; do
			tmpipconfig=$(az network nic ip-config list --nic-name ${VMPREFIX}-${count}VMNic -g $MyResourceGroup -o tsv --query [].name)
			az network nic ip-config update --name $tmpipconfig -g $MyResourceGroup --nic-name ${VMPREFIX}-${count}VMNic --remove publicIpAddress
		done
		# PBSのーども同様にインターネットからの外部接続を削除する
		tmpipconfig=$(az network nic ip-config list --nic-name ${VMPREFIX}-pbsVMNic -g $MyResourceGroup -o tsv --query [].name)
		az network nic ip-config update --name $tmpipconfig -g $MyResourceGroup --nic-name ${VMPREFIX}-pbsVMNic --remove publicIpAddress
	;;
esac


echo "end of vm hpc environment create script"
