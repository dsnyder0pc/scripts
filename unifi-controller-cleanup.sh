#!/bin/bash

# try these steps:
#
# https://help.ui.com/hc/en-us/articles/360006634094-UniFi-Network-Controller-Repairing-Database-Issues-on-the-UniFi-Controller

cd /tmp || exit 1
wget https://help.ui.com/hc/en-us/article_attachments/360008640574/CK_repair.js
service unifi stop
while pgrep java > /dev/null; do
  echo "Waiting for unifi service to stop..."
  sleep 5
done
mongod --dbpath /usr/lib/unifi/data/db --smallfiles --logpath /usr/lib/unifi/logs/server.log --repair
mongod --dbpath /usr/lib/unifi/data/db --smallfiles --logpath /usr/lib/unifi/logs/server.log --fork
mongo < /tmp/CK_repair.js
mongod --dbpath /usr/lib/unifi/data/db --smallfiles --logpath /usr/lib/unifi/logs/server.log --shutdown
service unifi start
