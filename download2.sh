#!/bin/bash

DL_URL=$1

BASE_URL="https://github.com/"

wget ${DL_URL} -O file1
grep .whl file1 | grep href | awk '{print $2}' | awk -F'"' '{print $2}' > download1
grep .so file1 | grep href | awk '{print $2}' | awk -F'"' '{print $2}' >> download1
grep .rpm file1 | grep href | awk '{print $2}' | awk -F'"' '{print $2}' >> download1
grep .deb file1 | grep href | awk '{print $2}' | awk -F'"' '{print $2}' >> download1

grep / download1 > download2

# create 
cat download1 | sed -e "s#^#${BASE_URL}#g" > download2

wget -nc -i download2

rm file1 file2
rm download1 download2
