#!/bin/bash

#サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>

MyResourceGroup=cfdbmt01
Location=japaneast
VMPREFIX=cfdbmt01
VMSIZE=Standard_HB120rs_v2 #Standard_HC44rs, Standard_HB120rs_v3

MyAvailabilitySet=${VMPREFIX}avset01
MyNetwork=${VMPREFIX}-vnet01
MySubNetwork=compute
MyNetworkSecurityGroup=${VMPREFIX}-nsg
# MyNic="cfdbmt-nic"
IMAGE="OpenLogic:CentOS-HPC:7_8:latest"
USERNAME=azureuser
# SSH公開鍵ファイルを指定
SSHKEYFILE="./${VMPREFIX}.pub"
TAG=${VMPREFIX}=$(date "+%Y%m%d")

MAXVM=10

# 追加の永続ディスクが必要な場合、ディスクサイズ(GB)を記入する https://azure.microsoft.com/en-us/pricing/details/managed-disks/
PERMANENTDISK=0

# 必要なパッケージ。Ubuntuの場合、以下のパッケージが必要
#sudo apt install -y parallel jq

### コマンド名取得
CMDNAME=`basename $0`

### コマンドオプションエラー処理
if [ $# -ne 1 ]; then
        echo "実行するには1個の引数が必要です。" 1>&2
        echo "create,delete,start,stop,list,remount 引数を一つ指定する必要があります。" 1>&2
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
                --priority 1000 --source-address-prefix Internet --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
                az vm availability-set create --name $MyAvailabilitySet -g $MyResourceGroup -l $Location --tags $TAG --output none
                numvm=0
                if [ -f ./vmlist ]; then
                        rm ./vmlist
                fi
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
                                --no-wait --tags $TAG &
                done
                while [ $((numvm)) -lt $((MAXVM)) ]; do
                        echo "sleep 30" && sleep 30
                        az vm list -g $MyResourceGroup | jq '.[] | .name' | grep ${VMPREFIX} > ./vmlist
                        numvm=$(cat ./vmlist | wc -l)
                done
                echo "careated VM list" && echo "$(cat ./vmlist)"
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
                cat ./ipaddresslist
                # 永続ディスクが必要な場合に設定可能
                if [ $((PERMANENTDISK)) -gt 0 ]; then
                        az vm disk attach --new -g $MyResourceGroup --size-gb $PERMANENTDISK --sku Premium_LRS --vm-name ${VMPREFIX}-1 --name ${VMPREFIX}-1-disk0
                fi
                echo "setting up nfs server"
                az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript \
                --scripts "sudo yum install -y nfs-utils && echo '/mnt/resource *(rw,no_root_squash,async)' >> /etc/exports"
                sleep 5
                az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript \
                --scripts "sudo chown ${USERNAME}:${USERNAME} /mnt/resource"
                az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript \
                --scripts "sudo systemctl start rpcbind && sudo systemctl start nfs"
                az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript \
                --scripts "sudo systemctl enable rpcbind && sudo systemctl enable nfs"
                echo "setting up nfs client"
                mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -otsv)
                seq 1 $MAXVM | parallel "az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-{} --command-id RunShellScript --scripts 'sudo yum install -y nfs-utils'"
                sleep 5
                count=0
                for count in $(seq 2 $MAXVM) ; do
                        az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "sudo mount -v -t nfs ${mountip}:/mnt/resource /mnt/resource" &
                done
                sleep 15
                echo "configuring fstab"
                for count in $(seq 2 $MAXVM) ; do
                        az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript \
                        --scripts "echo '/dev/sdb1    /mnt/resource    xfs    defaults    0    2' | sudo tee /etc/fstab"
                done
#               seq 2 $MAXVM | parallel -a ipaddresslist "ssh -t -t -i ./${VMPREFIX} $USERNAME@{} "echo '/dev/sdb1    /mnt/resource    xfs    defaults    0    2' | sudo tee /etc/fstab""
                # SSHパスワードレスセッティング
                echo "confugring passwordless settings"
                tmpfile=$(stat ./${VMPREFIX} -c '%a')
                cat ./ipaddresslist
                # SSH追加設定
cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
                case $tmpfile in
                        600 )
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./${VMPREFIX} $USERNAME@{}:/home/$USERNAME/.ssh/${VMPREFIX}"
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./${VMPREFIX} $USERNAME@{}:/home/$USERNAME/.ssh/id_rsa"
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t $USERNAME@{} "chmod 600 /home/$USERNAME/.ssh/id_rsa""
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./${VMPREFIX}.pub $USERNAME@{}:/home/$USERNAME/.ssh/${VMPREFIX}.pub"
                                # SSH追加設定
                                for count in `seq 1 $MAXVM` ; do
                                        line=$(sed -n ${count}P ./ipaddresslist)
                                        scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./config $USERNAME@${line}:/home/$USERNAME/.ssh/config
                                        ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${line} "chmod 600 /home/$USERNAME/.ssh/config"
                                done
                        ;;
                        7** )
                                # 何らかの事情でファイルパーミッションが設定できていない場合、~/.ssh/ディレクトリを利用する
                                cp ./${VMPREFIX} ~/.ssh/
                                chmod 600 ~/.ssh/${VMPREFIX}
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} ./${VMPREFIX} $USERNAME@{}:/home/$USERNAME/.ssh/${VMPREFIX}"
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} ./${VMPREFIX} $USERNAME@{}:/home/$USERNAME/.ssh/id_rsa"
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t $USERNAME@{} "chmod 600 /home/$USERNAME/.ssh/id_rsa""
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} ./${VMPREFIX}.pub $USERNAME@{}:/home/$USERNAME/.ssh/${VMPREFIX}.pub"
                                # SSH追加設定
                                for count in `seq 1 $MAXVM` ; do
                                        line=$(sed -n ${count}P ./ipaddresslist)
                                        scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./config $USERNAME@${line}:/home/$USERNAME/.ssh/config
                                        ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${line} "chmod 600 /home/$USERNAME/.ssh/config"
                                done
                        ;;
                esac
        ;;
        start )
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
                echo "nfs server @ ${VMPREFIX}-1"
                ipaddresstmp=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
#|\\|\\\|\\\|\\\|\\\|\\\vm1ip=$(head -1 ./ipaddresslist)
                echo "${VMPREFIX}-1's IP: $ipaddresstmp"
                mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -otsv)
                cat ./ipaddresslist
                tmpfile=$(stat ./${VMPREFIX} -c '%a')
                case $tmpfile in
                        600 )
                                echo "600:${VMPREFIX}-1: $vm1ip"
                                ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${ipaddresstmp} 'showmount -e'
                                echo "600:mounting: ${VMPREFIX}: 2-$MAXVM"
                                seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo mkdir -p /mnt/resource""
                                seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME /mnt/resource""
                                seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:/mnt/resource /mnt/resource""
                        ;;
                        7** )
                                # 何らかの事情でファイルパーミッションが設定できていない場合、~/.ssh/ディレクトリを利用する
                                cp ./${VMPREFIX} ~/.ssh/
                                chmod 600 ~/.ssh/${VMPREFIX}
                                echo "700:${VMPREFIX}-1: $vm1ip"
                                ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${ipaddresstmp} 'showmount -e'
                                echo "700:mounting: ${VMPREFIX}: 2-$MAXVM"
                                seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo mkdir -p /mnt/resource""
                                seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME /mnt/resource""
                                seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:/mnt/resource /mnt/resource""
                                ####for count in $(seq 2 $MAXVM) ; do
                                ####                    az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "mount -v -t nfs ${mountip}:/mnt/resource /mnt/resource"
                                ####            done
                                ####            rm ./tmpnumvm.txt
                        ;;
                esac
        ;;
        stop )
                for count in $(seq 1 $MAXVM) ; do
                        echo "stoping VM $count"
                        az vm stop -g $MyResourceGroup --name ${VMPREFIX}-${count} &
                done
        ;;
        list )
                echo "listng running(/stop) VM"
                az vm list -g $MyResourceGroup -d -o table
        ;;
        delete )
                if [ -f ./tmposdiskidlist ]; then
                        rm ./tmposdiskidlist
                fi
                for count in $(seq 1 $MAXVM) ; do
                        disktmp=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-${count} --query storageProfile.osDisk.managedDisk.id -o tsv)
                        echo $disktmp >> tmposdiskidlist
                done
                echo "deleting VM"
                seq 1 $MAXVM | parallel "az vm delete -g $MyResourceGroup --name ${VMPREFIX}-{} --yes &"
                rm ./ipaddresslist
                numvm=$(cat ./vmlist | wc -l)
                while [ $((numvm)) -gt 0 ]; do
                        echo "sleep 30" && sleep 30
                        echo "current running VMs: $numvm"
                        az vm list -g $MyResourceGroup | jq '.[] | .name' | grep ${VMPREFIX} > ./vmlist
                numvm=$(cat ./vmlist | wc -l)
                done
                rm ./vmlist
                echo "deleting disk"
                parallel -a tmposdiskidlist "az disk delete --ids {} --yes"
                sleep 10 && rm ./tmposdiskidlist
                echo "deleting nic"
                seq 1 $MAXVM | parallel "az network nic delete -g $MyResourceGroup --name ${VMPREFIX}-{}VMNic"
                echo "deleting public ip"
                seq 1 $MAXVM | parallel "az network public-ip delete -g $MyResourceGroup --name ${VMPREFIX}-{}PublicIP"
                echo "detele data disk"
                az disk delete -g $MyResourceGroup --name ${VMPREFIX}-1-disk0 --yes
                echo "current running VMs: ${numvm}"
        ;;
        remount )
                echo "current mounting status"
                seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "df | grep '/mnt/resource'""
                # mounting nfs server from compute node.
                numvm=$(cat ./ipaddresslist | wc -l)
                if [ -f ./ipaddresslist ]; then
                        ipaddresstmp=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
#                       |\\\|\\\|\\\vm1ip=$(head -1 ./ipaddresslist)
                        echo "${VMPREFIX}-1's IP: $ipaddresstmp"
                        mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -otsv)
                        tmpfile=$(stat ./${VMPREFIX} -c '%a')
                        case $tmpfile in
                                600 )
                                        echo "600:${VMPREFIX}-1: $vm1ip"
                                        ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${ipaddresstmp} 'showmount -e'
                                                echo "600:mounting: ${VMPREFIX}: 2-$MAXVM"
                                        seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo mkdir -p /mnt/resource""
                                        seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME /mnt/resource""
                                        seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:/mnt/resource /mnt/resource""
                                ;;
                                7** )
                                        echo "700:${VMPREFIX}-1: $vm1ip"
                                        ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} $USERNAME@${ipaddresstmp} 'showmount -e'
                                        echo "700:mounting: ${VMPREFIX}: 2-$MAXVM"
                                        seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo mkdir -p /mnt/resource""
                                        seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME /mnt/resource""
                                        seq 2 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ~/.ssh/${VMPREFIX} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:/mnt/resource /mnt/resource""
                                ;;
                        esac
                else
                        for count in $(seq 2 $MAXVM) ; do
                                az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-${count} --command-id RunShellScript --scripts "mount -t nfs ${mountip}:/mnt/resource /mnt/resource" &
                        done
                fi
        ;;
        pingpong )
                if [ -f ./nodelist ]; then
                        rm ./nodelist
                fi
                for count in $(seq 1 $MAXVM) ; do
                        nodelist=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-${count} -d --query privateIps -otsv)
                        echo $nodelist >> nodelist
                done
                if [ -f ./pingponglist ]; then
                        rm ./pingponglist
                fi
                for NODE in `cat ./nodelist`; do
                        for NODE2 in `cat ./nodelist`; do
                                echo "$NODE,$NODE2" >> pingponglist
                        done
                done
                # fullpingpongコマンド作成
                rm ./fullpingpong.sh
                # fullpingpong.sh作成
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
# ヒアドキュメントのルール上改行不可
EOL
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
                scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./fullpingpong.sh azureuser@$vm1ip:/home/azureuser/
                scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./pingponglist azureuser@$vm1ip:/home/azureuser/
                scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./fullpingpong.sh azureuser@$vm1ip:/mnt/resource/
                scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./pingponglist azureuser@$vm1ip:/mnt/resource/
                # SSH追加設定
                tmpfile=$(stat ./${VMPREFIX} -c '%a')
                cat ./ipaddresslist
                case $tmpfile in
                        600 )
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./config $USERNAME@{}:/home/$USERNAME/.ssh/config"
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} "chmod 600 /home/$USERNAME/.ssh/config""
                        ;;
                        7** )
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} ./config $USERNAME/@{}:/home/$USERNAME/.ssh/config"
                                seq 1 $MAXVM | parallel -v -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@{} "chmod 600 /home/$USERNAME/.ssh/config""
                        ;;
                esac
                # コマンド実行
                ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${vm1ip} "rm /mnt/resource/result"
                ssh -o StrictHostKeyChecking=no -i ./${VMPREFIX} $USERNAME@${vm1ip} "bash /mnt/resource/fullpingpong.sh > /mnt/resource/result"
                sleep 60
                scp -o StrictHostKeyChecking=no -i ./${VMPREFIX} azureuser@$vm1ip:/mnt/resource/result ./
        ;;
esac


echo "end of vm hpc environment create script"
