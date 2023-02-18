#!/bin/bash
#PBS -j oe
#PBS -q workq

cd $PBS_O_WORKDIR
 
echo "-------------------------------"
hostname
df -h
echo "-------------------------------"
echo '(1)'
grep physical.id /proc/cpuinfo | sort -u | wc -l
echo "-------------------------------"
echo '(2)'
grep cpu.cores /proc/cpuinfo | sort -u
echo "-------------------------------"
echo '(3)'
grep processor /proc/cpuinfo | wc -l
echo "-------------------------------"
echo 'When HT is OFF, (1) x (2) = (3). Check HT status of the node.'
echo "-------------------------------"
cat /proc/cpuinfo
echo "-------------------------------"
echo "firewall status : `systemctl status firewalld`"
sleep 10
