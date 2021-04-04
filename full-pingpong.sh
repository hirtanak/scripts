#!/bin/bash
# Example usage: ./full-pingpong.sh | grep -e ' 512 ' -e NODES -e usec

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