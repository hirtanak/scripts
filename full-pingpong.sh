#!/bin/bash

# pingponglist 作成：全ノードの組み合わせ作成
if [ -f ./pingponglist ]; then rm ./pingponglist; fi
for NODE in $(cat ./nodelist.txt); do
        for NODE2 in $(cat ./nodelist.txt); do
                echo "$NODE,$NODE2" >> pingponglist
        done
done

max=$(cat ./pingponglist | wc -l)
count=1
checkosver=$(cat /etc/redhat-release | cut  -d " " -f 4)
checkalama=$(cat /etc/redhat-release | cut  -d " " -f 1)
if [ $checkalama = "AlmaLinux" ]; then
  checkosver=$(cat /etc/redhat-release | cut  -d " " -f 3)
fi
## TZ=JST-9 date
echo "========================================================================"
echo -n "$(TZ=JST-9 date '+%Y %b %d %a %H:%M %Z')" && echo " - pingpong #: $max, OS: ${checkosver}"
echo "========================================================================"
# run pingpong
case $checkosver in
	7.?.???? )
		IMPI_VERSION=2018.4.274
		for count in `seq 1 $max`; do
			line=$(sed -n ${count}P ./pingponglist)
			echo "############### ${line} ###############"; >> result
			/opt/intel/impi/${IMPI_VERSION}/intel64/bin/mpirun -hosts $line -ppn 1 -n 2 -env I_MPI_FABRICS=shm:ofa /opt/intel/impi/${IMPI_VERSION}/bin64/IMB-MPI1 pingpong | grep -e ' 512 ' -e NODES -e usec; >> result
		done
	;;
	8.?.???? )
		IMPI_VERSION=latest #2021.1.1
		 source /opt/intel/oneapi/mpi/${IMPI_VERSION}/env/vars.sh
		for count in `seq 1 $max`; do
			line=$(sed -n ${count}P ./pingponglist)
			echo "############### ${line} ###############"; >> result
			/opt/intel/oneapi/mpi/${IMPI_VERSION}/bin/mpiexec -hosts $line -ppn 1 -n 2 /opt/intel/oneapi/mpi/${IMPI_VERSION}/bin/IMB-MPI1 pingpong | grep -e ' 512 ' -e NODES -e usec; >> result
		done
	;;
esac
