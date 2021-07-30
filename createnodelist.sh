#!/bin/bash
#MAXVM=2
#MyResourceGroup=sample
#VMPREFIX=sample

# ホストファイル作成準備：既存ファイル削除
if [ -f ./nodelist ]; then rm ./nodelist; echo "recreating a new nodelist"; fi
# ホストファイル作成
az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine.{VirtualMachine:name,PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv > tmphostsfile
# 自然な順番でソートする
sort -V ./tmphostsfile > hostsfile
# nodelist 取り出し：2列目
cat hostsfile | cut -f 2 > nodelist
# テンポラリファイル削除
rm ./tmphostsfile
