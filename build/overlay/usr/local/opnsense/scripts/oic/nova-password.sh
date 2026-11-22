#!/bin/sh
# openimages.cloud: store the generated root password, already encrypted with
# the instance RSA key, for `nova get-password`. Started detached by
# firstboot.php: the metadata service may answer only once DHCP completes,
# well after the start syshook (several minutes on some clouds).
# Usage: nova-password.sh <dir holding pw.enc>  (the dir is removed after)
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
dir="$1"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" >> /var/log/oic-firstboot.log; }
code=000
i=0
while [ $i -lt 60 ]; do
  code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST \
    --data-binary "@$dir/pw.enc" http://169.254.169.254/openstack/latest/password 2>/dev/null)
  case "$code" in
    200) log "generated password stored for nova get-password"; break ;;
    000) ;;                       # not reachable yet
    409) log "a password was already stored for nova get-password: kept"; break ;;
    *) log "metadata service refused the password (HTTP $code): not stored for nova get-password"; break ;;
  esac
  i=$((i + 1))
  sleep 5
done
[ "$code" = 000 ] && log "metadata service unreachable for 5 minutes: password not stored for nova get-password (it is on the console)"
rm -rf "$dir"
