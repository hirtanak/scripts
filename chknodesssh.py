#!/usr/bin/python
# coding: UTF-8

# For Azure HPC node avialability via ssh
# Current user can access without password to others
# Node file Format
# /home/azureuser/bin/nodenames.txt
# xxxxxyyyy0000zz
# xxxxxyyyy0000zz

import subprocess

f = open("/home/azureuser/bin/nodenames.txt")
lines2 = f.readlines()
f.close()

for line in lines2:
    line = line.replace("\n", "")
    cmd = ("ssh %s uname -a" % (line))
    print(cmd)
    try:
        subprocess.call(cmd.strip().split(" "))
    except:
        print "Error"
