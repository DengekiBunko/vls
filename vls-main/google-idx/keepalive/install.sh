#!/usr/bin/env sh

# 1. pull docker image
docker pull jlesage/firefox

# 2. init directory
mkdir -p app/firefox/idx
mkdir -p app/idx-keepalive
cd app/idx-keepalive

# 3. download keepalive scripts & install dependencies
wget https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/google-idx/keepalive/app.js
wget https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/google-idx/keepalive/package.json
npm install

# 4. create startup.sh
wget https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/google-idx/keepalive/startup.sh
sed -i 's#$PWD#'$PWD'#g' startup.sh
chmod +x startup.sh

# 5. return main directory
cd -
