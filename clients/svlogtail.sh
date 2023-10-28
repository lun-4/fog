#!/bin/sh

set -eux

hostname=$(hostname)
 
tail -Fq -n0 /var/log/socklog/*/current | while read -r line; do
    curl -H "Fog-Hostname: $hostname" -d "$line" -X POST localhost:9741/log
done

