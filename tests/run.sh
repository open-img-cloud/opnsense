#!/usr/bin/env bash
# Boot test of the built image under KVM: tests/run.sh <qcow2> <scenario>
#   configdrive : 1 NIC, config drive, RSA key, plain password in user data
#   nocloud     : 1 NIC, Proxmox-style NoCloud drive, ed25519 key, crypt hash
#   metadata    : 2 NICs, metadata service only, RSA key, no password
#                 (generated: console + nova get-password)
set -uo pipefail
img=$1; sc=$2; W=${W:-$PWD/work-$sc}; mkdir -p "$W"
fail=0; ok() { echo "PASS $*"; }; ko() { echo "FAIL $*"; fail=1; }
o=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -o BatchMode=yes)

case $sc in
  configdrive|metadata) ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -f "$W/key" ;;
  nocloud) ssh-keygen -q -t ed25519 -N '' -f "$W/key" ;;
esac
pub=$(cat "$W/key.pub"); host="oic-$sc"; uuid=$(cat /proc/sys/kernel/random/uuid)
meta=$(jq -n --arg u "$uuid" --arg h "$host.example.org" --arg k "$pub" '{uuid:$u,name:"oic",hostname:$h,public_keys:{test:$k}}')
pw_plain="Oic-$(openssl rand -hex 6)"
extra=()
case $sc in
  configdrive)
    mkdir -p "$W/cd/openstack/latest"; echo "$meta" > "$W/cd/openstack/latest/meta_data.json"
    printf '#cloud-config\npassword: %s\n' "$pw_plain" > "$W/cd/openstack/latest/user_data"
    genisoimage -quiet -o "$W/drive.iso" -V config-2 -J -R "$W/cd"
    extra=(-drive file="$W/drive.iso",media=cdrom) ;;
  nocloud)
    mkdir -p "$W/nc"; printf 'instance-id: %s\nlocal-hostname: %s\n' "$uuid" "$host" > "$W/nc/meta-data"
    hash=$(openssl passwd -6 "$pw_plain")
    printf '#cloud-config\nhostname: %s\nmanage_etc_hosts: true\nfqdn: %s\nuser: root\npassword: %s\nssh_authorized_keys:\n  - %s\nchpasswd:\n  expire: False\nusers:\n  - default\npackage_upgrade: true\n' "$host" "$host" "$hash" "$pub" > "$W/nc/user-data"
    genisoimage -quiet -o "$W/drive.iso" -V cidata -J -R "$W/nc/meta-data" "$W/nc/user-data"
    extra=(-drive file="$W/drive.iso",media=cdrom) ;;
  metadata)
    mkdir -p "$W/md"; echo "$meta" > "$W/md/meta_data.json" ;;
esac

qemu-img create -q -f qcow2 -F qcow2 -b "$img" "$W/disk.qcow2" 12G
net0="user,id=n0,hostfwd=tcp::2222-:22,hostfwd=tcp::8443-:443"
# slirp only forwards addresses inside its own network: put the WAN in
# 169.254.169.0/24 so 169.254.169.254 can reach the metadata emulator.
[[ $sc == metadata ]] && net0+=",net=169.254.169.0/24,host=169.254.169.2,dns=169.254.169.3,dhcpstart=169.254.169.15,guestfwd=tcp:169.254.169.254:80-cmd:env MD_DIR=$W/md python3 $PWD/tests/md_stdio.py"
nets=(-netdev "$net0" -device virtio-net-pci,netdev=n0)
[[ $sc == metadata ]] && nets+=(-netdev user,id=n1,net=10.9.0.0/24 -device virtio-net-pci,netdev=n1)
qemu-system-x86_64 -accel kvm -cpu host -smp 2 -m 2048 -nographic \
  -drive file="$W/disk.qcow2",if=virtio "${extra[@]}" "${nets[@]}" \
  -chardev socket,path="$W/qga.sock",server=on,wait=off,id=qga0 -device virtio-serial \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -serial file:"$W/console.log" -monitor none -display none &
qpid=$!

R() { ssh "${o[@]}" -i "$W/key" -p 2222 root@127.0.0.1 'sh -s' <<< "$1"; }
t0=$SECONDS; up=0
while (( SECONDS - t0 < 600 )); do
  if R 'test -f /conf/oic-instance-id' 2>/dev/null; then up=1; break; fi
  sleep 10
done
(( up )) && ok "SSH as root with the injected key, first boot done after $((SECONDS - t0))s" || { ko "no SSH with the key within 600s"; }

if (( up )); then
  sleep 5
  echo "--- oic-firstboot.log"; R 'cat /var/log/oic-firstboot.log'
  [[ "$(R 'hostname -s')" == "$host" ]] && ok "hostname $host" || ko "hostname is $(R 'hostname')"
  # password: the hash of root in config.xml must verify the expected one
  case $sc in
    configdrive|nocloud) want="$pw_plain" ;;
    metadata) want=$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' "$W/console.log" | sed -n 's/^  password: \(.*\)$/\1/p' | tail -1) ;;
  esac
  if [[ -n "$want" ]] && R "php -r 'require_once \"config.inc\"; require_once \"auth.inc\"; \$u=getUserEntryByUID(0); exit(password_verify(\$argv[1], \$u[\"password\"]) ? 0 : 1);' -- '$want'"; then
    ok "root password matches the $sc source"
  else
    ko "root password does not match (expected from $sc)"
  fi
  if [[ $sc != metadata ]]; then
    grep -q "$pw_plain" "$W/console.log" && ko "user-data password printed on the console" || ok "user-data password not printed on the console"
  else
    [[ -n "$want" ]] && ok "generated password on the serial console" || ko "no generated password on the console"
    # stored by a detached retry loop: give it a moment
    for _ in $(seq 1 12); do [[ -s "$W/md/password" ]] && break; sleep 5; done
    if [[ -s "$W/md/password" ]]; then
      dec=$(openssl base64 -d -A < "$W/md/password" | openssl pkeyutl -decrypt -inkey "$W/key" 2>/dev/null)
      [[ "$dec" == "$want" ]] && ok "password stored for nova get-password decrypts to the console one" || ko "nova password does not decrypt to the console one"
    else
      ko "no password POSTed to the metadata service"
    fi
    [[ "$(R "php -r 'require_once \"config.inc\"; echo \$config[\"interfaces\"][\"lan\"][\"if\"] ?? \"none\";'")" == vtnet1 ]] && ok "LAN on vtnet1 (second NIC)" || ko "LAN not on vtnet1"
  fi
  code=$(curl -sk -o "$W/gui.html" -w '%{http_code}' https://127.0.0.1:8443/)
  grep -qi opnsense "$W/gui.html" && ok "web GUI answers on the WAN (HTTP $code)" || ko "web GUI not reachable on the WAN (HTTP $code)"
  root_gb=$(( $(R "df -k / | awk 'NR==2 {print \$2}'") / 1024 / 1024 ))
  (( root_gb >= 10 )) && ok "root filesystem grown (${root_gb} GB of 12)" || ko "root filesystem not grown (${root_gb} GB)"
  R 'mount | grep -q " /var (tmpfs\|mfs" ' && ko "/var still in memory" || ok "/var on disk"
  opts=$(R "ifconfig vtnet0 | sed -n 's/.*options=[0-9a-f]*<\\(.*\\)>.*/\\1/p'")
  [[ ",$opts," == *",TXCSUM,"* && ",$opts," == *",TSO4,"* && ",$opts," != *",LRO,"* ]] \
    && ok "vtnet0 offloads: checksum and TSO on, LRO off" || ko "vtnet0 offloads not as expected: $opts"
  qga=$( (printf '{"execute":"guest-ping"}\n'; sleep 2) | timeout 10 socat -t 4 - UNIX-CONNECT:"$W/qga.sock")
  [[ "$qga" == *return* ]] && ok "qemu-guest-agent answers" || ko "qemu-guest-agent silent"
  methods=$( { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=none -p 2222 nobody@127.0.0.1 true 2>&1 || true; } | sed -n 's/.*Permission denied (\(.*\)).*/\1/p')
  [[ ",$methods," == *",password,"* || ",$methods," == *",keyboard-interactive,"* ]] && ko "sshd offers $methods" || ok "sshd offers only $methods"
fi
kill $qpid 2>/dev/null; wait $qpid 2>/dev/null
echo "--- console (tail)"; sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$W/console.log" | grep -v "^\s*$" | tail -40 | sed -E 's/(password: ).*/\1<redacted in the log>/'
exit $fail
