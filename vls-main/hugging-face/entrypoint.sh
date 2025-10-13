#!/usr/bin/env sh

sed -i "s/UUID/$UUID/g" /app/xy/config.json
sed -i "s/DOMAIN/$DOMAIN/g" /app/keepalive.sh

# cp /etc/resolv.conf /etc/resolv.conf.bak
# echo "nameserver 1.1.1.1" > /etc/resolv.conf
# echo "nameserver 8.8.8.8" >> /etc/resolv.conf

# (crontab -l 2>/dev/null; echo "*/5 * * * * /app/keepalive.sh") | crontab -

exec "$@"
