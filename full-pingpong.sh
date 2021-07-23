#!/bin/bash
# Example usage: ./full-pingpong.sh | grep -e ' 512 ' -e NODES -e usec
checkosver=$(cat /etc/redhat-release | cut  -d " " -f 4)
count=1
## TZ=JST-9 date
echo "========================================================================"
echo -n "$(TZ=JST-9 date '+%Y %b %d %a %H:%M %Z')" && echo " - pingpong #: $max, OS: ${checkosver}"
echo "========================================================================"
# run pingpong
case $checkosver in
    7.?.???? )
    IMPI_VERSION=2018.4.274
    for NODE in `cat ./nodelist.txt`; \
        do for NODE2 in `cat ./nodelist.txt`; \
            do echo '##################################################' && \
                echo NODES: $NODE, $NODE2 && \
                echo '##################################################' && \
                /opt/intel/impi/${IMPI_VERSION}/intel64/bin/mpirun \
                -hosts $NODE,$NODE2 -ppn 1 -n 2 \
                -env I_MPI_FABRICS=shm:dapl \
                -env I_MPI_DYNAMIC_CONNECTION=0 /opt/intel/impi/${IMPI_VERSION}/intel64/bin/IMB-MPI1 pingpong; \
            done; \
        done
    ;;
    8.?.???? )
    IMPI_VERSION=2021.2.0
    source /opt/intel/oneapi/mpi/2021.2.0/env/vars.sh
    for NODE in `cat ./nodelist.txt`; \
        do for NODE2 in `cat ./nodelist.txt`; \
            do echo '##################################################' && \
                echo NODES: $NODE, $NODE2 && \
                echo '##################################################' && \
                /opt/intel/oneapi/mpi/${IMPI_VERSION}/bin/mpirun \
                -hosts $NODE,$NODE2 -ppn 1 -n 2 \
                /opt/intel/oneapi/mpi/${IMPI_VERSION}/bin/IMB-MPI1 pingpong; \
            done; \
        done
    ;;
esac
