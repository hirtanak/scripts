#!/bin/bash

if [ `hostname` == 'ip-AC1D1104' -a `whoami` == 'root' ]
then
  hostname
  sudo sh -c 'echo "/scratch  *(rw,no_root_squash)" > /etc/exports.d/export-nfs.exports'
  sudo exportfs -ar
  sudo exportfs -v
  sudo systemctl start nfs-server
  sudo systemctl status nfs-server
else
  echo "mount trying..."
  sudo mount -t nfs ip-AC1D1104:/scratch /scratch
fi
