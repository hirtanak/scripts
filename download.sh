#!/usr/bin/bash

url="https://github.com/Azure/cyclecloud-slurm/releases/tag/2.1.0"

rm alldl_list.txt
rm dl_list.txt

declare -a exe
declare -a exe=(".tar.gz" ".so" ".deb" ".rpm")

curl $url | grep -o -e "<a href=\".*\">" | awk '{print $2}' | awk -F "\"" '{print $2}' > alldl_list.txt


for i in ${exe[@]}; do
   grep $i alldl_list.txt >> dl_list.txt
done

sed -i 's/^/wget https:\/\/github.com/g' dl_list.txt
sed '2,4d' dl_list.txt

bash dl_list.txt
