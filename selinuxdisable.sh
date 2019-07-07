#!/bin/bash

NP=8

cat ~/machinefile${NP} | while read line
do
    echo "${line%:15}"
    ssh -t -t azureuser@${line%:15} <<EOC
    hostname
    sudo setenforce 0
    exit
EOC
done
