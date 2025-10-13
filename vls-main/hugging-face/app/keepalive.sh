#!/usr/bin/env sh

status=$(curl -o /dev/null -s -w "%{http_code}" https://DOMAIN)
echo `date "+%Y-%m-%d %H:%M:%S"` - Request: https://DOMAIN, Response: $status > /tmp/keepalive.log
