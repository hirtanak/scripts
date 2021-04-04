#!/bin/bash
# Example usage: ./full-pingpong.sh | grep -e ' 512 ' -e NODES -e usec

for NODE in `cat ~/nodenames.txt`; \
    do for NODE2 in `cat ~/nodenames.txt`; \
        do echo '##################################################' && \
            echo NODES: $NODE, $NODE2 && \
            echo '##################################################' && \
            /opt/intel/impi/5.1.3.181/bin64/mpirun \
            -hosts $NODE,$NODE2 -ppn 1 -n 2 \
            -env I_MPI_FABRICS=dapl \
            -env I_MPI_DAPL_PROVIDER=ofa-v2-ib0 \
            -env I_MPI_DYNAMIC_CONNECTION=0 /opt/intel/impi/5.1.3.181/bin64/IMB-MPI1 pingpong; \
        done; \
    done

