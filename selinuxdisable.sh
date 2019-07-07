#!/bin/bash

NODES=64

cat ~/machinefile${NODES} | while read line
do
    echo "${line%:15}"
    ssh -t -t  -l cyclecloud -i <file> ${line%:15} <<EOC
    hostname
    sudo setenforce 0
    exit
EOC
done
