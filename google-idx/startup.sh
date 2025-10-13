#!/usr/bin/env sh

nohup $PWD/xray -c $PWD/config.json 1>$PWD/xray.log 2>&1 &
