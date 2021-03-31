#!/bin/bash

MyResourceGroup=tmcbmt01
Location=japaneast
VMPREFIX=tmcbmt01
VMSIZE=Standard_HB120rs_v2 #Standard_D2as_v4 #Standard_HC44rs, Standard_HB120rs_v3
PBSVMSIZE=Standard_D2as_v4

MyAvailabilitySet=${VMPREFIX}avset01
MyNetwork=${VMPREFIX}-vnet01
MySubNetwork=compute
MySubNetwork2=management # ログインノード用
MyNetworkSecurityGroup=${VMPREFIX}-nsg
LIMITEDIP=$(curl -s ifconfig.io)/32 #利用しているクライアントのグローバルIPアドレスを取得
echo "current client global ip address: $LIMITEDIP. This script defines the ristricted access from this client"
LIMITEDIP2=113.40.3.153/32 #追加制限IPアドレスをCIRDで記載 例：1.1.1.0/24
echo "addtional accessible CIDR: $LIMITEDIP2"
# MyNic="cfdbmt-nic"
IMAGE="OpenLogic:CentOS-HPC:7_8:latest" #Azure URNフォーマット
USERNAME=azureuser
# SSH公開鍵ファイルを指定
SSHKEYFILE="./${VMPREFIX}.pub"
TAG=${VMPREFIX}=$(date "+%Y%m%d")
#
MAXVM=2
# 追加の永続ディスクが必要な場合、ディスクサイズ(GB)を記入する https://azure.microsoft.com/en-us/pricing/details/managed-disks/
PERMANENTDISK=0
PBSPERMANENTDISK=128
# 必要なパッケージ。Ubuntuの場合、以下のパッケージが必要
#sudo apt install -y parallel jq curl
DEBUG="" #"-v"

# コマンド名取得
CMDNAME=`basename $0`

# コマンドオプションエラー処理
if [ $# -ne 1 ]; then
	echo "実行するには1個の引数が必要です。" 1>&2
	echo "create,delete,start,stop,list,remount,pingpong,addlogin,updatensg,privatenw,publicnw の引数を一つ指定する必要があります。" 1>&2
	echo "1. create コマンド: コンピュートノードを作成します" 1>&2
	echo "2. addlogin コマンド: login, PBSノードを作成します" 1>&2
	echo "3. privatenw コマンド: コンピュートノード、PBSノードからグローバルIPアドレスを除きます" 1>&2
	echo "stop コマンド: すべてのコンピュートノードを停止します。" 1>&2
	exit 1
fi
# SSH鍵チェック。なければ作成
if [ ! -f "./${VMPREFIX}" ] || [ ! -f "./${VMPREFIX}.pub" ] ; then
	ssh-keygen -f ./${VMPREFIX} -m pem -t rsa -N "" -b 4096
fi
# SSH秘密鍵ファイルのディレクトリ決定
tmpfile=$(stat ./${VMPREFIX} -c '%a')
case $tmpfile in
	600 )
		SSHKEYDIR="./${VMPREFIX}"
	;;
	7** )
		cp ./${VMPREFIX} ~/.ssh/
		chmod 600 ~/.ssh/${VMPREFIX}
		SSHKEYDIR="~/.ssh/${VMPREFIX}"
	;;
esac
echo "SSHKEYDIR: $SSHKEYDIR"

### ログイン処理
# サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>

# サービスプリンシパルの利用も可能以下のパラメータとログイン処理を有効にすること
#azure_name="uuid"
#azure_password="uuid"
#azure_tenant="uuid"

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
			for count in `seq 1 10`; do
				checkssh=$(ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t $USERNAME@${vm1ip} "uname")
				if [ ! -z "$checkssh" ]; then
					break
				fi
				echo "waiting sshd @ ${VMPREFIX}-1: sleep 10" && sleep 10
			done
		echo "checkssh connectiblity for ${VMPREFIX}-1: $checkssh"
		if [ -z "$checkssh" ]; then
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript \
				--scripts "sudo yum install -y nfs-utils && echo '/mnt/resource *(rw,no_root_squash,async)' >> /etc/exports"
			sleep 5
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo chown ${USERNAME}:${USERNAME} /mnt/resource"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo systemctl start rpcbind && sudo systemctl start nfs"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo systemctl enable rpcbind && sudo systemctl enable nfs"
		else
			# SSH設定が高速
			echo "sudo 設定"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "sudo cat /etc/sudoers | grep $USERNAME" > sudotmp
			if [ -z "$sudotmp" ]; then
				ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers"
			fi
			unset sudotmp && rm ./sudotmp
			echo "debug"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "sudo cat /etc/sudoers | grep $USERNAME"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "sudo yum install --quiet -y nfs-utils"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "echo '/mnt/resource *(rw,no_root_squash,async)' | sudo tee /etc/exports"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "sudo chown ${USERNAME}:${USERNAME} /mnt/resource"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "sudo systemctl start rpcbind && sudo systemctl start nfs"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "sudo systemctl enable rpcbind && sudo systemctl enable nfs"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "sudo showmount -e"
		fi
		echo "setting up nfs client"
		mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -otsv)
		echo "mountip: $mountip"
		# 1行目を削除したIPアドレスリストを作成
		sed '1d' ./ipaddresslist > ./ipaddresslist-tmp
		# sudo設定
		echo "sudo 設定"
		for count in `seq 1 $((MAXVM-1))`; do
			line=$(sed -n ${count}P ./ipaddresslist-tmp)
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo cat /etc/sudoers | grep $USERNAME" > sudotmp
			if [ -z "$sudotmp" ]; then
#			parallel $DEBUG -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${} -t "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers""
				echo "sudo: setting by ssh command"
				ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers"
				ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo grep $USERNAME /etc/sudoers"
			unset sudotmp && rm ./sudotmp
			else
				echo "sudo: setting by run-command"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "echo '$USERNAME ALL=NOPASSWD: ALL' | sudo tee -a /etc/sudoers"
			fi
		done
		# 高速化のためにSSHで一括設定しておく
		echo "600: ssh parallel settings: nfs client"
		parallel $DEBUG -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y nfs-utils""
		parallel $DEBUG -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mkdir -p /mnt/resource""
		parallel $DEBUG -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource""
		parallel $DEBUG -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource""
		# NFSサーバ・マウント設定
		rm ./ipaddresslist-tmp
		count=2
		for count in `seq 2 $MAXVM` ; do
			line=$(sed -n ${count}P ./ipaddresslist)
			for cnt in `seq 1 10`; do
				checkssh=$(ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "uname")
				if [ ! -z "$checkssh" ]; then
					break
				fi
					echo "waiting sshd @ ${VMPREFIX}-${count}: $checkssh sleep 10" && sleep 10
			done
			if [ ! -z "$checkssh" ]; then
				echo "600: setting by ssh command"
				ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo yum install -y nfs-utils"
				ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo mkdir -p /mnt/resource"
				ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource"
				ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource"
				ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "echo '/dev/sdb1    /mnt/resource    xfs    defaults    0    2' | sudo tee /etc/fstab"
			else
				echo "600: setting by az vm run-command"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts 'sudo yum install -y nfs-utils'
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mkdir -p /mnt/resource"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo chown $USERNAME:$USERNAME /mnt/resource"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript \
					--scripts "echo '/dev/sdb1    /mnt/resource    xfs    defaults    0    2' | sudo tee /etc/fstab"
			fi
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
		echo "600: configuring passwordless settings"
		parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./${VMPREFIX} $USERNAME@{}:/home/$USERNAME/.ssh/${VMPREFIX}"
		parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./${VMPREFIX} $USERNAME@{}:/home/$USERNAME/.ssh/id_rsa"
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa""
		parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./${VMPREFIX}.pub $USERNAME@{}:/home/$USERNAME/.ssh/${VMPREFIX}.pub"
		# SSH追加設定
		for count in `seq 1 $MAXVM` ; do
			line=$(sed -n ${count}P ./ipaddresslist)
			scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./config $USERNAME@${line}:/home/$USERNAME/.ssh/config
			ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${line} -t -t "chmod 600 /home/$USERNAME/.ssh/config"
		done
	;;
	start )
		## PBSノード：OSディスクタイプ変更: Premium_LRS
		azure_sku2="Premium_LRS"
		osdiskidpbs=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs --query storageProfile.osDisk.managedDisk.id -o tsv)
#		az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs --query storageProfile.osDisk.managedDisk.id -o table
		if [ ! -z "$osdiskidpbs" ]; then
			az disk update --sku ${azure_sku2} --ids ${osdiskidpbs} --query [].tier
		## PBSノード：Dataディスクタイプ変更: Premium_LRS
			az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs --query storageProfile.dataDisks[*].managedDisk -o tsv | awk -F" " '{ print $2}' | xargs -I{} az disk update --sku ${azure_sku2} --ids {}
			echo "starting PBS VM"
			az vm start -g $MyResourceGroup --name ${VMPREFIX}-pbs --query powerState
			# 今のところPBSノードが存在すればログインノードも存在する
			echo "starting loging VM"
			az vm start -g $MyResourceGroup --name ${VMPREFIX}-login --query powerState
		else
			echo "no PBS node here!"
		fi
		echo "starting VM ${VMPREFIX}-1"
		az vm start -g $MyResourceGroup --name ${VMPREFIX}-1 --query powerState
		echo "starting VM ${VMPREFIX}:2-$MAXVM compute nodes"
		seq 2 $MAXVM | parallel "az vm start -g $MyResourceGroup --name ${VMPREFIX}-{} --query powerState"
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
			while [ -z "$ipaddresstmp" ]; do
				ipaddresstmp=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-${count} --query publicIps -o tsv)
				echo "ip: $ipaddresstmp"
			done
			echo $ipaddresstmp >> ipaddresslist
		done
		echo "current ip address list"
		cat ./ipaddresslist
		# コンピュートノード#1：マウント設定
		echo "nfs server @ ${VMPREFIX}-1"
		vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-${count} --query publicIps -o tsv)
		echo "${VMPREFIX}-1's IP: $vm1ip"
		mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -o tsv)
		# インターネットからアクセス可能であれば、SSHで高速に設定する
		if [ -z "$vm1ip" ]; then
			# vm1ipが空なら、IPアドレスが取得できなければ、az cliでの取得
			for count in $(seq 2 $MAXVM) ; do
				# 並列化・時間短縮は検討事項
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mkdir -p /mnt/resource"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo chown $USERNAME:$USERNAME /mnt/resource"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource"
			done
		else
			# vm1ipが空でなければSSHでマウントを実施
			echo "600:${VMPREFIX}-1: $vm1ip"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} 'sudo showmount -e'
			# 1行目を削除したIPアドレスリストを作成
			sed '1d' ./ipaddresslist > ./ipaddresslist-tmp
			echo "600:mounting: ${VMPREFIX}: 2-$MAXVM"
			parallel $DEBUG -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mkdir -p /mnt/resource""
			parallel $DEBUG -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource""
			parallel $DEBUG -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource""
		fi
		echo "end of starting up computing nodes"
		# PBSノードがなければ終了
		if [ -z "$osdiskidpbs" ]; then
			echo "no PBS node here!"
			exit 0
		fi
		# PBSノード：マウント設定
		echo "pbsnode: nfs server @ ${VMPREFIX}-pbs"
		# PBSノード：名前取得
		pbsvmname=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query name -o tsv)
		# PBSノード：グローバルIPアドレス取得
		pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
		echo "${VMPREFIX}-pbs's IP: $pbsvmip"
		# PBSノード：マウント向けプライベートIPアドレス取得
		pbsmountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs -d --query privateIps -otsv)
		# インターネットからアクセス可能であれば、SSHで高速に設定する
		if [ -z "$pbsvmname" ]; then
			# vm1ipが空なら、IPアドレスが取得できなければ、az cliでの取得
			if [ -z "$pbsvmip" ]; then
				# コンピュートノード#1のみ実施
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mkdir -p /mnt/share"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo chown $USERNAME:$USERNAME /mnt/share"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mount $DEBUG -t nfs ${pbsmountip}:/mnt/share /mnt/share"
				for count in $(seq 2 $MAXVM) ; do
				# コンピュートノード#1をマウント
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mkdir -p /mnt/share"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo chown $USERNAME:$USERNAME /mnt/share"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mount $DEBUG -t nfs ${pbsmountip}:/mnt/share /mnt/share"
				done
			else
				# pbsbmipが空でなければSSHでマウント情報の取得
				echo "600:${VMPREFIX}-1: $pbsvmip"
				ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} 'sudo showmount -e'
				echo "600:mounting ${VMPREFIX}-pbs /mnt/share @ 1-$MAXVM"
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mkdir -p /mnt/share""
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chown $USERNAME:$USERNAME /mnt/share""
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mount $DEBUG -t nfs ${pbsmountip}:/mnt/share /mnt/share""
				# vm1ipが空でなければSSHでマウント情報の取得
				echo "600:${VMPREFIX}-1: $vm1ip"
				ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} 'sudo showmount -e'
				echo "600:mounting: ${VMPREFIX}: 2-$MAXVM"
				parallel $DEBUG -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mkdir -p /mnt/resource""
				parallel $DEBUG -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource""
				parallel $DEBUG -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mount $DEBUG -t nfs ${mountip}:/mnt/resource /mnt/resource""
				rm ./ipaddresslist-tmp
			fi
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
		# OSディスクタイプ変更: Standard_LRS
		azure_sku1="Standard_LRS"
#		osdiskidpbs=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs --query storageProfile.osDisk.managedDisk.id -o tsv)
#		osdiskid1=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 --query storageProfile.osDisk.managedDisk.id -o tsv)
		echo "converting computing node OS disk"
		parallel -v -a ./tmposdiskidlist "az disk update --sku ${azure_sku1} --ids {}"
		# Dataディスクタイプ変更: Standard_LRS
		echo "converting PBS node data disk"
		az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs --query storageProfile.dataDisks[*].managedDisk -o tsv | awk -F" " '{ print $2}' | xargs -I{} az disk update --sku ${azure_sku1} --ids {}
		echo "converting compute node #1 data disk"
		az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 --query storageProfile.dataDisks[*].managedDisk -o tsv | awk -F" " '{ print $2}' | xargs -I{} az disk update --sku ${azure_sku1} --ids {}
	;;
	list )
		echo "listng running/stop VM"
		az vm list -g $MyResourceGroup -d -o table
		echo "nfs server vm status"
		vm1state=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query powerState)
		vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
		pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
		if [ -z "$pbsvmip" ]; then
			echo "no PBS node here! checking only compute nodes."
			# コンピュートノードのみのチェック
			count=0
			checkssh=$(ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t $USERNAME@${vm1ip} "uname")
			if [ ! -z "$checkssh" ]; then
				echo "${VMPREFIX}-1: nfs server status"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${vm1ip} 'sudo showmount -e'
				echo "nfs client mount status"
					for count in `seq 2 $MAXVM`; do
						line=$(sed -n ${count}P ./ipaddresslist)
						ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} -t -t $USERNAME@${line} "echo '########## host: ${VMPREFIX}-: 2 - ${count} ##########'"
						ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} -t -t $USERNAME@${line} "df | grep '/mnt/'"
					done
				else
					# SSHできないのでaz vm run-commandでの情報取得
					echo "600: az vm run-command: nfs server status"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo showmount -e"
					echo "nfs client mount status:=======1-2 others: skiped======="
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "df | grep /mnt/"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-2 --command-id RunShellScript --scripts "df | grep /mnt/"
			fi
			# コマンド完了
			echo "end of list command"
			exit 0
		fi
		# PBSノード、コンピュートノードのNFSマウント確認
		count=0
		checkssh=$(ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t $USERNAME@${vm1ip} "uname")
		checkssh2=$(ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t $USERNAME@${pbsvmip} "uname")
		if [ ! -z "$checkssh" -a ! -z "$checkssh2" ]; then
			echo "${VMPREFIX}-pbs: nfs server status"
			ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} 'sudo showmount -e'
			echo "${VMPREFIX}-1: nfs server status"
			ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${vm1ip} 'sudo showmount -e'
			echo "nfs client mount status"
			for count in `seq 2 $MAXVM`; do
				line=$(sed -n ${count}P ./ipaddresslist)
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} -t -t $USERNAME@${line} "echo '########## host: ${VMPREFIX}-${count} ##########'"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} -t -t $USERNAME@${line} "df | grep '/mnt/'"
			done
		else
			echo "600: az vm run-command: nfs server status"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "sudo showmount -e"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo showmount -e"
			echo "nfs client mount status:=======1-2 others: skiped======="
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "df | grep /mnt/"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-2 --command-id RunShellScript --scripts "df | grep /mnt/"
		fi
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
		rm ./nodelist
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
		echo "detelting data disk"
		az disk delete -g $MyResourceGroup --name ${VMPREFIX}-1-disk0 --yes
		az disk delete -g $MyResourceGroup --name ${VMPREFIX}-pbs-disk0 --yes
		echo "current running VMs: ${numvm}"
		# ファイル削除
		rm ./ipaddresslist
		rm ./tmposdiskidlist
		rm ./vmlist
		rm ./config
		rm ./fullpingpong.sh
		rm ./pingponlist
		rm ./nodelist
		rm ./hostsfile
		rm ./loginvmip
		rm ./pbsvmip
		rm ./md5*
		rm ./hostsfile
		rm ./openpbs*
		rm ./pbsprivateip
		rm ./tmpcheckhostsfile
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
			echo "current mounting status"
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "df | grep '/mnt/resource'""
			echo "600:${VMPREFIX}-1: $vm1ip"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${ipaddresstmp} 'sudo showmount -e'
			echo "600:mounting: ${VMPREFIX}: 2-$MAXVM"
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mkdir -p /mnt/resource""
			parallel $DEUBG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME /mnt/resource""
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:/mnt/resource /mnt/resource""
			if [ ! -z "$pbsmountip" ]; then
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mkdir -p /mnt/share""
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME /mnt/share""
				parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:/mnt/share""
			fi
		else
			for count in $(seq 2 $MAXVM) ; do
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mount -t nfs ${mountip}:/mnt/resource /mnt/resource" &
			done
			echo "sleep 180" && sleep 180
			for count in $(seq 2 $MAXVM) ; do
				if [ ! -z "$pbsmountip" ]; then
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mount -t nfs ${pbdmountip}:/mnt/share /mnt/share" &
					sleep 10
				fi
			done
		fi
	;;
	pingpong )
		# コマンド実行判断
		vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
		if [ -z "$vm1ip" ]; then
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
		# fullpingpong実行
		echo "pingpong: preparing files"
#		vm1ip=$(head -1 ./ipaddresslist)
		impidir=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${vm1ip} "ls /opt/intel/impi/")
		cat ./pingponglist
		scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./fullpingpong.sh $USERNAME${vm1ip}:/home/$USERNAME/
		scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./pingponglist $USERNAME@${vm1ip}:/home/$USERNAME/
		scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./fullpingpong.sh $USERNAME@${vm1ip}:/mnt/resource/
		scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./pingponglist $USERNAME@${vm1ip}:/mnt/resource/
		# SSH追加設定
		cat ./ipaddresslist
		echo "pingpong: copy passwordless settings"
		seq 1 $MAXVM | parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./config $USERNAME@{}:/home/$USERNAME/.ssh/config"
		seq 1 $MAXVM | parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "chmod 600 /home/$USERNAME/.ssh/config""
		# コマンド実行
		echo "pingpong: running pingpong for all compute nodes"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "rm /mnt/resource/result"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "bash /mnt/resource/fullpingpong.sh > /mnt/resource/result"
		scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${vm1ip}:/mnt/resource/result ./
		echo "ローカルのresultファイルを確認"
	;;
#### ==========================================================================
	# ログインノード、PBSノードを作成します。
	addlogin )
		# 既存ネットワークチェック
		tmpsubnetwork=$(az network vnet subnet show -g $MyResourceGroup --name $MySubNetwork2 --vnet-name $MyNetwork --query id)
		echo "current subnetowrk id: $tmpsubnetwork"
		if [ -z "$tmpsubnetwork" ]; then
			# mgmtサブネット追加
			az network vnet subnet create -g $MyResourceGroup --vnet-name $MyNetwork -n $MySubNetwork2 --address-prefixes 10.0.1.0/24 --network-security-group $MyNetworkSecurityGroup -o table
		fi
		# ログインノード作成
		echo "================== creating login node =================="
		az vm create \
			--resource-group $MyResourceGroup --location $Location \
			--name ${VMPREFIX}-login \
			--size Standard_D2a_v4 \
			--vnet-name $MyNetwork --subnet $MySubNetwork2 \
			--nsg $MyNetworkSecurityGroup --nsg-rule SSH \
			--public-ip-address-allocation static \
			--image $IMAGE \
			--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
			--tags $TAG -o table
		# PBSジョブスケジューラノード作成
		echo "================== creatig PBS node =================="
		az vm create \
			--resource-group $MyResourceGroup --location $Location \
			--name ${VMPREFIX}-pbs \
			--size $PBSVMSIZE \
			--vnet-name $MyNetwork --subnet $MySubNetwork \
			--nsg $MyNetworkSecurityGroup --nsg-rule SSH \
			--public-ip-address-allocation static \
			--image $IMAGE \
			--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
			--tags $TAG -o table
		# LoginノードIPアドレス取得
		loginvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-login --query publicIps -o tsv)
		echo $loginvmip > ./loginvmip
		# PBSノードIPアドレス取得
		pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
		echo $pbsvmip > ./pbsvmip
		# 永続ディスクが必要な場合に設定可能
		if [ $((PBSPERMANENTDISK)) -gt 0 ]; then
			az vm disk attach --new -g $MyResourceGroup --size-gb $PBSPERMANENTDISK --sku Premium_LRS --vm-name ${VMPREFIX}-pbs --name ${VMPREFIX}-pbs-disk0 -o table &
		fi
		# SSHパスワードレスセッティング
		echo "pbsnode: prparing passwordless settings"
		# カレントディレクトににファイルがない場合にのみ、SSH config設定作成
		if [ ! -f ./config ]; then
		cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
		fi
		# ログインノード：パスワードレス設定
		echo "ログインノード: confugring passwordless settings"
		scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./${VMPREFIX} $USERNAME@${loginvmip}:/home/$USERNAME/.ssh/${VMPREFIX}
		scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./${VMPREFIX} $USERNAME@${loginvmip}:/home/$USERNAME/.ssh/id_rsa
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${loginvmip} -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
		scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./${VMPREFIX}.pub $USERNAME@${loginvmip}:/home/$USERNAME/.ssh/${VMPREFIX}.pub
		# SSH Config設定
		scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./config $USERNAME@${loginvmip}:/home/$USERNAME/.ssh/config
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${loginvmip} -t -t "chmod 600 /home/$USERNAME/.ssh/config"
		# PBSノード：パスワードレス設定
		echo "600: PBSノード: confugring passwordless settings"
		scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./${VMPREFIX} $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/${VMPREFIX}
		scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./${VMPREFIX} $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/id_rsa
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
		scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./${VMPREFIX}.pub $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/${VMPREFIX}.pub
		# SSH Config設定
		scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./config $USERNAME@${pbsvmip}:/home/$USERNAME/.ssh/config
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "chmod 600 /home/$USERNAME/.ssh/config"
		# PBSノード：sudo設定
		echo "sudo 設定"
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo cat /etc/sudoers | grep $USERNAME" > sudotmp
		sudotmp=$(cat ./sudotmp)
		if [ -z "$sudotmp" ]; then
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers"
		fi
		unset sudotmp && rm ./sudotmp
		# PBSノード：ディスクフォーマット
		echo "600: disk formatting"
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "df | grep sdc1" > tmpformat
		tmpformat=$(cat ./tmpformat)
		if [ "$tmpformat" ]; then
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo parted /dev/sdc --script mklabel gpt mkpart xfspart xfs 0% 100%"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo mkfs.xfs /dev/sdc1"
			ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo partprobe /dev/sdc1"
		fi
		rm ./tmpformat
		# PBSノード：ディレクトリ設定
		echo "600: directory setting"
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo mkdir -p /mnt/share"
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo mount $DEBUG /dev/sdc1 /mnt/share"
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo chown $USERNAME:$USERNAME /mnt/share"
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "ls -la /mnt"
		# NFS設定
		echo "600: nfs server settings"
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo yum install --quiet -y nfs-utils"
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "echo '/mnt/share *(rw,no_root_squash,async)' | sudo tee /etc/exports"
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo systemctl start rpcbind && sudo systemctl start nfs"
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo systemctl enable rpcbind && sudo systemctl enable nfs"
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo showmount -e"
		# PBSノード：NFSマウント設定
		pbsmountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs -d --query privateIps -otsv)
		echo "600: mouting new directry on compute nodes: /mnt/share"
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mkdir -p /mnt/share""
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chown $USERNAME:$USERNAME /mnt/share""
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mount $DEBUG -t nfs ${pbsmountip}:/mnt/share /mnt/share""

		# PBSノード：インストール準備
		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo yum install --quiet -y md5sum"
		# ローカル：openPBSバイナリダウンロード
		baseurl="https://github.com/hirtanak/scripts/releases/download/0.0.1"
		wget -q $baseurl/openpbs-server-20.0.1-0.x86_64.rpm -O ./openpbs-server-20.0.1-0.x86_64.rpm
		md5sum ./openpbs-server-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1 > ./md5server
		md5server=$(cat ./md5server)
		while [ ! "$md5server" = "6e7a7683699e735295dba6e87c6b9fd0" ]; do
			rm ./openpbs-server-20.0.1-0.x86_64.rpm
			wget -q $baseurl/openpbs-server-20.0.1-0.x86_64.rpm -O ./openpbs-server-20.0.1-0.x86_64.rpm
		done
		wget -q $baseurl/openpbs-client-20.0.1-0.x86_64.rpm -O ./openpbs-client-20.0.1-0.x86_64.rpm
		md5sum ./openpbs-client-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1 > ./md5client
		md5client=$(cat ./md5client)
		while [ ! "$md5client" = "7bcaf948e14c9a175da0bd78bdbde9eb" ]; do
			rm ./openpbs-client-20.0.1-0.x86_64.rpm
			wget -q $baseurl/openpbs-client-20.0.1-0.x86_64.rpm -O ./openpbs-client-20.0.1-0.x86_64.rpm
		done
		wget -q $baseurl/openpbs-execution-20.0.1-0.x86_64.rpm -O ./openpbs-execution-20.0.1-0.x86_64.rpm
		md5sum ./openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1 > ./md5execution
		md5execution=$(cat ./md5execution)
		while [ ! "$md5execution" = "59f5110564c73e4886afd579364a4110" ]; do
			rm ./openpbs-client-20.0.1-0.x86_64.rpm
			wget -q $baseurl/openpbs-client-20.0.1-0.x86_64.rpm -O ./openpbs-client-20.0.1-0.x86_64.rpm
		done
		if [ ! -f ./openpbs-server-20.0.1-0.x86_64.rpm ] || [ ! -f ./openpbs-client-20.0.1-0.x86_64.rpm ] || [ ! -f ./openpbs-execution-20.0.1-0.x86_64.rpm ]; then
			echo "file download error!. please download manually OpenPBS file in current diretory"
			echo "openPBSバイナリダウンロードエラー。githubにアクセスできないネットワーク環境の場合、カレントディレクトリにファイルをダウンロードする方法でも可能"
			exit 1
		fi
		# hostsfileファイル作成準備：既存ファイル削除
		if [ -f ./hostsfile ]; then
			rm ./hostsfile
		fi
		if [ -f ./nodefile ]; then
			rm ./nodefile
		fi
		# hostsfileファイル作成準備：プライベートIPアドレス取得
		for count in $(seq 1 $MAXVM) ; do
			nodelist=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-${count} -d --query privateIps -o tsv)
			echo $nodelist >> nodelist
		done
		# hostsfileファイル作成
		paste ./nodelist ./vmlist > ./hostsfile
		# ダブルクォーテーション削除
		sed -i -e "s/\"//g" ./hostsfile
		# hostsfileファイル作成
		pbsprivateip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs -d --query privateIps -o tsv)
		echo "$pbsprivateip" > pbsprivateip
		echo "${VMPREFIX}-pbs" > hosttmpfile
		paste ./pbsprivateip ./hosttmpfile > hosttmpfile2
		cat ./hosttmpfile2 >> ./hostsfile
		cat ./hostsfile
		rm ./hosttmpfile
		rm ./hosttmpfile2
		# PBSノード：OpenPBSサーバコピー＆インストール
		echo "copy openpbs-server-20.0.1-0.x86_64.rpm"
#				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "md5sum /home/$USERNAME/openpbs-server-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1" > md5server-remote
#				echo "md5server-remote: $md5server-remote"
#				while [ ! "$md5server"="6e7a7683699e735295dba6e87c6b9fd0" ]; do
#					ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "rm /home/$USERNAME/openpbs-server-20.0.1-0.x86_64.rpm"
		scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./openpbs-server-20.0.1-0.x86_64.rpm $USERNAME@${pbsvmip}:/home/$USERNAME/
#					ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "md5sum /home/$USERNAME/openpbs-server-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1 > md5server-remote"
#					md5server=$(cat ./md5server-remote)
#					echo "md5server: $mdserver"
#				done
#				md5client=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "md5sum /home/$USERNAME/openpbs-client-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1")
#				echo "md5client: $md5client"
#				while [ ! "$md5client"="7bcaf948e14c9a175da0bd78bdbde9eb" ]; do
#					ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "rm /home/$USERNAME//openpbs-client-20.0.1-0.x86_64.rpm"
		scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./openpbs-client-20.0.1-0.x86_64.rpm $USERNAME@${pbsvmip}:/home/$USERNAME/
#					ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "md5sum /home/$USERNAME/openpbs-server-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1 > md5client-remote"
#					md5client=$(cat ./md5client-remote)
#					echo "md5client: $mdclient"
#				done
		# PBSノード：openPBS requirement
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo yum install --quiet -y expat libedit postgresql-server postgresql-contrib python3 sendmail sudo tcl tk libical"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo yum install --quiet -y hwloc-libs libICE libSM"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "ls -la ~/"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-server-20.0.1-0.x86_64.rpm"

		# openPBSをビルドする場合：現在は利用していない
#		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "wget -q https://github.com/openpbs/openpbs/archive/refs/tags/v20.0.1.tar.gz -O /home/$USERNAME/openpbs-20.0.1.tar.gz"
#		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "tar zxvf /home/$USERNAME/openpbs-20.0.1.tar.gz"
#		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "LANG=C /home/$USERNAME/openpbs-20.0.1/autogen.sh"
#		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "LANG=C /home/$USERNAME/openpbs-20.0.1/configure --prefix=/opt/pbs"
#		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "make"
#		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo make install"

		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-client-20.0.1-0.x86_64.rpm"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo /opt/pbs/libexec/install_db"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo /opt/pbs/libexec/pbs_habitat"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo /opt/pbs/libexec/pbs_postinstall"
		# PBSノード：configure /etc/pbs.conf file
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo sed -i -e 's/PBS_START_SERVER=0/PBS_START_SERVER=1/g' /etc/pbs.conf"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo sed -i -e 's/PBS_START_SCHED=0/PBS_START_SCHED=1/g' /etc/pbs.conf"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo sed -i -e 's/PBS_START_COMM=0/PBS_START_COMM=1/g' /etc/pbs.conf"
		# PBSノード：openPBSパーミッション設定
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_iff"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_rcp"
		# PBSノード：HOSTSファイルコピー
		echo "copy hostsfile to all compute nodes"
		scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./hostsfile $USERNAME@${pbsvmip}:/home/$USERNAME/
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo grep ${VMPREFIX} /etc/hosts" > tmpcheckhostsfile
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo /etc/hosts | grep ${VMPREFIX}"
		if [ ! -s "$tmpcheckhostsfile" ]; then
			for count in `seq 1 $MAXVM`; do
				scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./hostsfile $USERNAME@${VMPREFIX}-${count}:/home/$USERNAME/
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${VMPREFIX}-${count} -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
				ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo /etc/hosts | grep ${VMPREFIX}"
			done
		fi
		rm ./tmpcheckhostsfile
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "ln -s /mnt/share/ /home/$USERNAME/"
### ===========================================================================
		# PBSノード：openPBSクライアントコピー
		echo "copy openpbs-execution-20.0.1-0.x86_64.rpm to all compute nodes"
		parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
		# ダウンロード、およびMD5チェック
		count=0
		rm ./md5executionremote
		rm ./md5executionremote2
		for count in `seq 1 $MAXVM`; do
			line=$(sed -n ${count}P ./ipaddresslist)
			ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${line} -t -t "md5sum /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1" > md5executionremote
			md5executionremote=$(cat ./md5executionremote)
			echo "md5executionremote: $md5executionremote"
			for cnt in `seq 1 3`; do
				if [ "$md5executionremote" == "$md5execution" ]; then
				# 固定ではうまくいかない
				# if [ "$md5executionremote" != "59f5110564c73e4886afd579364a4110" ]; then
					ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${line} -t -t "rm /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm"
					scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@${line}:/home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm
					ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${line} -t -t "md5sum /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1" > md5executionremote
					md5executionremote=$(cat ./md5executionremote)
					echo "md5executionremote: $md5executionremote"
					echo "md5executionremote2: $md5executionremote2"
					for cnt in `seq 1 3`; do
						if [ "$md5executionremote2" != "$md5execution" ]; then
						# 固定ではうまくいかない
						# if [ "$md5executionremote2" != "59f5110564c73e4886afd579364a4110" ]; then
							ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${line} -t -t "rm /tmp/openpbs-execution-20.0.1-0.x86_64.rpm"
							ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${line} -t -t "wget -q $baseurl/openpbs-execution-20.0.1-0.x86_64.rpm -O /tmp/openpbs-execution-20.0.1-0.x86_64.rpm"
							ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${line} -t -t "md5sum /tmp/openpbs-execution-20.0.1-0.x86_64.rpm  | cut -d ' ' -f 1" > md5executionremote2
							md5executionremote2=$(cat ./md5executionremote2)
							ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${line} -t -t "cp /tmp/openpbs-execution-20.0.1-0.x86_64.rpm /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm"
							echo "md5executionremote2: $md5executionremote2"
						else
							echo "match md5 by md5executionremote2"
							md5executionremote2=$(cat ./md5executionremote2)
							break
						fi
					done
				else
					echo "match md5 by md5executionremote"
					md5executionremote=$(cat ./md5executionremote)
					break
				fi
			done
		done
		rm ./md5executionremote
		rm ./md5executionremote2
		# openPBSクライアント：インストール
		echo "confuguring all compute nodes"
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y hwloc-libs libICE libSM""
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y libnl3""
		echo "installing libnl3"
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm""
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo rpm -aq | grep openpbs""
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo /opt/pbs/libexec/pbs_habitat""
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo /opt/pbs/libexec/pbs_postinstall""
		# pbs.confファイル生成
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e 's/PBS_START_MOM=0/PBS_START_MOM=1/g' /etc/pbs.conf""
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /etc/pbs.conf""
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo cat /etc/pbs.conf""
		# openPBSクライアント：パーミッション設定
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_iff""
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_rcp""
		# openPBSクライアント：/var/spool/pbs/mom_priv/config コンフィグ設定
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config""
		for count in `seq 1 $MAXVM` ; do
			line=$(sed -n ${count}P ./ipaddresslist)
			ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config"
		done
		# openPBSクライアント：HOSTSファイルコピー
		parallel $DEBUG -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./hostsfile $USERNAME@{}:/home/$USERNAME/"
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts""
		for count in `seq 1 $MAXVM` ; do
			line=$(sed -n ${count}P ./ipaddresslist)
			ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${line} -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
			ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo cat /etc/hosts"
		done
### ===========================================================================
		# PBSプロセス起動
		# PBSノード起動＆$USERNAME環境変数設定
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "yes | sudo /etc/init.d/pbs start"
		fi
		# openPBSクライアントノード起動＆$USERNAME環境変数設定
		parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo /etc/init.d/pbs start""
		vm1ip=$(cat ./ipaddresslist | head -n 1)
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			parallel $DEBUG -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'echo 'source /etc/profile.d/pbs.sh' >> ~/.bashrc'"
		fi
		rm ./pbssh
		echo "finished to set up additonal login and PBS node"
### ===========================================================================
		# PBSジョブスケジューラセッティング
		echo "configpuring PBS settings"
		for count in `seq 1 $MAXVM`; do
			echo "sudo /opt/pbs/bin/qmgr -c "create node ${VMPREFIX}-${count}"" >> setuppbs.sh
		done
		echo "setuppbs.sh: `cat ./setuppbs.sh`"
		scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} ./setuppbs.sh $USERNAME@${pbsvmip}:/home/$USERNAME/setuppbs.sh
		ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo bash /home/$USERNAME/setuppbs.sh"
#		sed -i -e "s/\"//g" ./vmlist > vmlist2
#		parallel $DEBUG -a vmlist2 "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 180' -i ${SSHKEYDIR} $USERNAME@{pbsvmip} -t -t "sudo /opt/pbs/bin/qmgr -c 'create node {}'""
	;;
	updatensg )
		# NSGアップデート：既存の実行ホストからのアクセスを修正
		echo "current host global ip address: $LIMITEDIP"
		echo "updating NSG for current host global ip address"
		az network nsg rule update --name ssh --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
			--priority 1000 --source-address-prefix $LIMITEDIP --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 -o table
		az network nsg rule update --name ssh2 --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
			--priority 1010 --source-address-prefix $LIMITEDIP2 --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 -o table
	;;
	privatenw )
		# PBSノード、コンピュートノード：インターネットからの外部接続を削除
		echo "既存のクラスターからインターネットからの外部接続を削除"
		count=0
		for count in `seq 1 $MAXVM`; do
			tmpipconfig=$(az network nic ip-config list --nic-name ${VMPREFIX}-${count}VMNic -g $MyResourceGroup -o tsv --query [].name)
			az network nic ip-config update --name $tmpipconfig -g $MyResourceGroup --nic-name ${VMPREFIX}-${count}VMNic --remove publicIpAddress -o table &
		done
		# PBSノードも同様にインターネットからの外部接続を削除する
		tmpipconfig=$(az network nic ip-config list --nic-name ${VMPREFIX}-pbsVMNic -g $MyResourceGroup -o tsv --query [].name)
		az network nic ip-config update --name $tmpipconfig -g $MyResourceGroup --nic-name ${VMPREFIX}-pbsVMNic --remove publicIpAddress -o table &
	;;
	publicnw )
#		done
		# PBSノード、コンピュートノード：インターネットからの外部接続を確立
		echo "既存のクラスターからインターネットからの外部接続を確立します"
		count=0
		for count in `seq 1 $MAXVM`; do
			tmpipconfig=$(az network nic ip-config list --nic-name ${VMPREFIX}-${count}VMNic -g $MyResourceGroup -o tsv --query [].name)
			az network nic ip-config update --name ipconfig${VMPREFIX}-${count} -g $MyResourceGroup --nic-name ${VMPREFIX}-${count}VMNic --public ${VMPREFIX}-${count}PublicIP -o table &
		done
		# PBSノードも同様にインターネットからの外部接続を追加する
		tmpipconfig=$(az network nic ip-config list --nic-name ${VMPREFIX}-pbsVMNic -g $MyResourceGroup -o tsv --query [].name)
		az network nic ip-config update --name ipconfig${VMPREFIX}-pbs -g $MyResourceGroup --nic-name ${VMPREFIX}-pbsVMNic --public ${VMPREFIX}-pbsPublicIP -o table &
	;;
esac


echo "$CMDNAME: end of vm hpc environment create script"
