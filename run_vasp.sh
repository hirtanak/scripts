#!/bin/bash
#PBS -q workq

# VASP Base Dir
#export VASP_BASE=/mnt/exports/shared/home/azureuser/apps/vasp
export VASP_BASE=""

# Intel env
. /opt/intel/mkl/bin/intel64/mklvars_intel64.sh
. /opt/intel/impi/2018.4.274/intel64/bin/mpivars.sh intel64
. /opt/intel/parallel_studio_xe_2018.4.057/compilers_and_libraries_2018/linux/bin/compilervars.sh intel64

# Path
export PATH=$VASP_BASE/usr/local/openmpi-2.1.5-intel64-v14.0.4/bin:$PATH
export PATH=$VASP_BASE/usr/local/ucx-1.5.1/bin:$PATH

# Library Path
export LD_LIBRARY_PATH=$VASP_BASE/opt/intel/mkl/lib/intel64:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=$VASP_BASE/opt/intel/composer_xe_2013_sp1.4.211/compiler/lib/intel64:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=$VASP_BASE/usr/local/openmpi-2.1.5-intel64-v14.0.4/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=$VASP_BASE/usr/local/ucx-1.5.1/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=$VASP_BASE/usr/local/vasp:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=$VASP_BASE/usr/local/vasp.5.lib:$LD_LIBRARY_PATH

# OpenMPI-4.0.3 under /opt
#export PATH=/opt/openmpi-4.0.3/bin:$PATH
#export LD_LIBRARY_PATH=/opt/openmpi-4.0.3/lib:$LD_LIBRARY_PATH

cd $PBS_O_WORKDIR

# Run VASP
#/opt/intel/impi/2018.4.274/intel64/bin/mpirun $VASP_BASE/usr/local/vasp.5.3/vasp
which mpirun
ldd $VASP_BASE/usr/local/vasp.5.3/vasp
mpirun -np 16 $VASP_BASE/usr/local/vasp.5.3/vasp > output.txt 2>&1
