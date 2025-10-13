#!/usr/bin/env sh

cd $PWD
nohup npm run start 1>idx-keepalive.log 2>&1 &
