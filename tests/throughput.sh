#!/usr/bin/env bash
# Network throughput on OpenStack (virtio-net) of the published images.
#
#   tests/throughput.sh            (OS_* credentials in the environment)
#
# VMs on the public network (ext-net1), all from the published catalog files:
#   srv   Debian 13, iperf3 server (the reference end of every test)
#   deb   Debian 13, client: Linux baseline
#   bsd   FreeBSD 15, client
#   opn   OPNsense: WAN on ext-net1, LAN on a private 192.168.1.0/24 network
#   lan   Debian 13 on that LAN only: its traffic is routed and NATed by opn
#         (it reports on its serial console, it has no public address)
# Each client runs iperf3 against srv: 1 stream and 4 streams, upload and
# download (-R). The FreeBSD-based VMs also report their vtnet state
# (offloads, MTU, queues). Results go to $GITHUB_STEP_SUMMARY when set.
set -uo pipefail

CDN=https://images.openimages.cloud
FLAVOR=${FLAVOR:-a2-ram4-disk20-perf1}
EXTNET=${EXTNET:-ext-net1}
T=oic-perf-${GITHUB_RUN_ID:-local}
W=$(mktemp -d)
SUM=${GITHUB_STEP_SUMMARY:-/dev/stdout}
O=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes -i "$W/id")
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

cleanup() {
  set +e
  log "cleanup"
  for s in srv deb bsd opn lan; do openstack server delete --wait "$T-$s" 2>/dev/null; done
  for p in opn-lan lan; do openstack port delete "$T-$p" 2>/dev/null; done
  openstack subnet delete "$T-lan" 2>/dev/null
  openstack network delete "$T-lan" 2>/dev/null
  for i in debian bsd opn; do openstack image delete "$T-$i" 2>/dev/null; done
  openstack keypair delete "$T" 2>/dev/null
  openstack security group delete "$T" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT

ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -f "$W/id"
openstack keypair create --public-key "$W/id.pub" "$T" >/dev/null
openstack security group create "$T" >/dev/null
for r in "--proto tcp --dst-port 22" "--proto tcp --dst-port 5201" "--proto icmp"; do
  # shellcheck disable=SC2086
  openstack security group rule create $r "$T" >/dev/null
done

# --- images, from the published catalog files --------------------------------
image() { # <catalog id> <glance name>
  local m f
  m=$(curl -fsS -A oic-check "$CDN/$1/latest/MANIFEST.json")
  f=$(jq -r .filename <<<"$m")
  log "image $1 $(jq -r .version <<<"$m")"
  curl -fsSL -A oic-check -o "$W/$f" "$CDN/$1/$(jq -r .version <<<"$m")/$f"
  openstack image create --disk-format qcow2 --container-format bare --file "$W/$f" \
    --property hw_qemu_guest_agent=yes --property hw_vif_multiqueue_enabled=true \
    "$2" >/dev/null
  rm -f "$W/$f"
}
image debian-13 "$T-debian"
image freebsd-15 "$T-bsd"
image opnsense "$T-opn"

# --- LAN behind OPNsense -------------------------------------------------------
openstack network create "$T-lan" >/dev/null
openstack subnet create --network "$T-lan" --subnet-range 192.168.1.0/24 \
  --gateway 192.168.1.1 --allocation-pool start=192.168.1.100,end=192.168.1.199 \
  --dns-nameserver 192.168.1.1 "$T-lan" >/dev/null
# OPNsense routes for the LAN and serves DHCP on it too: no port security there.
openstack port create --network "$T-lan" --fixed-ip subnet="$T-lan",ip-address=192.168.1.1 \
  --disable-port-security --no-security-group "$T-opn-lan" >/dev/null
openstack port create --network "$T-lan" --disable-port-security --no-security-group "$T-lan" >/dev/null

# --- servers ---------------------------------------------------------------------
cat > "$W/srv.yaml" <<'EOF'
#cloud-config
packages: [iperf3]
runcmd:
  - [sh, -c, "iperf3 -s -D"]
EOF
boot() { # <name> <image> [extra args]
  local n=$1 i=$2; shift 2
  openstack server create --flavor "$FLAVOR" --image "$T-$i" --key-name "$T" "$@" "$T-$n" >/dev/null \
    && log "boot $n" || log "boot $n FAILED"
}
boot srv debian --network "$EXTNET" --security-group "$T" --user-data "$W/srv.yaml"
boot deb debian --network "$EXTNET" --security-group "$T"
boot bsd bsd --network "$EXTNET" --security-group "$T"
boot opn opn --nic net-id="$(openstack network show -f value -c id "$EXTNET")" \
  --nic port-id="$(openstack port show -f value -c id "$T-opn-lan")" --security-group "$T"

ip4() { openstack server show -f json -c addresses "$1" | jq -r '[.addresses[][]] | map(select(test("^[0-9.]+$")))[0]'; }
waitssh() { # <user> <ip>
  for _ in $(seq 1 60); do ssh "${O[@]}" "$1@$2" true </dev/null 2>/dev/null && return 0; sleep 10; done
  return 1
}
for _ in $(seq 1 60); do
  [[ "$(openstack server list --name "^$T-" -f value -c Status | sort -u)" == ACTIVE ]] && break; sleep 5
done
SRV=$(ip4 "$T-srv"); DEB=$(ip4 "$T-deb"); BSD=$(ip4 "$T-bsd"); OPN=$(ip4 "$T-opn")
log "srv $SRV deb $DEB bsd $BSD opn $OPN"

# The LAN client needs srv's address: boot it now. It reports on its console.
cat > "$W/lan.yaml" <<EOF
#cloud-config
packages: [iperf3]
runcmd:
  - - sh
    - -c
    - |
      for i in \$(seq 1 60); do iperf3 -c $SRV -t 2 >/dev/null 2>&1 && break; sleep 10; done
      for a in "-P 1" "-P 4" "-P 1 -R" "-P 4 -R"; do
        r=\$(iperf3 -c $SRV -t 15 \$a -J 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin)["end"]; print(round(d["sum_received"]["bits_per_second"]/1e6))' 2>/dev/null)
        echo "OICPERF \$a \${r:-fail}" > /dev/ttyS0
      done
      echo "OICPERF mtu \$(cat /sys/class/net/*/mtu | head -1)" > /dev/ttyS0
      echo "OICPERF done" > /dev/ttyS0
EOF
boot lan debian --nic port-id="$(openstack port show -f value -c id "$T-lan")" --user-data "$W/lan.yaml"

waitssh debian "$SRV" || log "srv: no SSH"
for _ in $(seq 1 30); do ssh "${O[@]}" "debian@$SRV" 'pgrep -x iperf3' </dev/null >/dev/null 2>&1 && break; sleep 10; done

# --- clients -------------------------------------------------------------------
# <label> <ssh target> <remote shell prefix>: runs the 4 iperf3 cases from it
run_iperf() {
  local label=$1 tgt=$2 a r
  for a in "-P 1" "-P 4" "-P 1 -R" "-P 4 -R"; do
    r=$(ssh "${O[@]}" "$tgt" "sh -s" <<<"iperf3 -c $SRV -t 15 $a -J" 2>/dev/null \
      | jq -r '(.end.sum_received.bits_per_second // 0) / 1e6 | floor' 2>/dev/null)
    echo "$label|$a|${r:-fail}" >> "$W/results"
    log "$label $a: ${r:-fail} Mbit/s"
  done
}
vtnet_state() { # <label> <ssh target>
  ssh "${O[@]}" "$2" "sh -s" > "$W/vtnet-$1.txt" 2>&1 <<'EOF'
ifconfig vtnet0 | sed -n '1,4p'
sysctl -n dev.vtnet.0.max_vq_pairs dev.vtnet.0.act_vq_pairs 2>/dev/null | paste -sd' ' - | sed 's/^/queues max act: /'
sysctl -n hw.ncpu | sed 's/^/ncpu: /'
EOF
}

waitssh debian "$DEB" && { ssh "${O[@]}" "debian@$DEB" 'sudo apt-get -qq update && sudo apt-get -qq install -y iperf3' >/dev/null 2>&1; run_iperf "Debian 13" "debian@$DEB"; }
if waitssh freebsd "$BSD"; then
  ssh "${O[@]}" "freebsd@$BSD" 'sudo env ASSUME_ALWAYS_YES=yes pkg install -y iperf3' >/dev/null 2>&1
  vtnet_state bsd "freebsd@$BSD"; run_iperf "FreeBSD 15" "freebsd@$BSD"
else log "bsd: no SSH"; fi
if waitssh root "$OPN"; then
  ssh "${O[@]}" "root@$OPN" "sh -s" <<<'env ASSUME_ALWAYS_YES=yes pkg install -y iperf3' >/dev/null 2>&1
  vtnet_state opn "root@$OPN"; run_iperf "OPNsense (host)" "root@$OPN"
  ssh "${O[@]}" "root@$OPN" "sh -s" > "$W/opn-offload.txt" 2>&1 <<'EOF'
php -r 'require_once "config.inc"; foreach (["disablechecksumoffloading","disablesegmentationoffloading","disablelargereceiveoffloading"] as $k) echo "$k=", ($config["system"][$k] ?? "unset"), "\n";'
EOF
else log "opn: no SSH"; fi

# LAN client, routed and NATed by OPNsense
for _ in $(seq 1 60); do
  openstack console log show "$T-lan" 2>/dev/null | tr -d '\r' | grep -q "OICPERF done" && break; sleep 10
done
openstack console log show "$T-lan" 2>/dev/null | tr -d '\r' | grep "^OICPERF -P" | while read -r _ p n r rest; do
  a="$p $n"; [[ "$r" == "-R" ]] && { a="$a -R"; r=$rest; }
  echo "Through OPNsense (LAN to WAN, NAT)|$a|$r" >> "$W/results"
done
lanmtu=$(openstack console log show "$T-lan" 2>/dev/null | tr -d '\r' | grep -m1 "^OICPERF mtu" | awk '{print $3}')

# --- report --------------------------------------------------------------------
mtu=$(openstack network show -f value -c mtu "$EXTNET" 2>/dev/null)
lmtu=$(openstack network show -f value -c mtu "$T-lan" 2>/dev/null)
{
  echo "## Throughput on Infomaniak ($OS_REGION_NAME, $FLAVOR), iperf3 to a Debian 13 server, Mbit/s"
  echo
  echo "| Client | 1 stream up | 4 streams up | 1 stream down | 4 streams down |"
  echo "|---|---|---|---|---|"
  for c in "Debian 13" "FreeBSD 15" "OPNsense (host)" "Through OPNsense (LAN to WAN, NAT)"; do
    row="| $c"
    for a in "-P 1" "-P 4" "-P 1 -R" "-P 4 -R"; do
      row="$row | $(grep -F "$c|$a|" "$W/results" 2>/dev/null | head -1 | cut -d'|' -f3)"
    done
    echo "$row |"
  done
  echo
  echo "Network MTU: $EXTNET $mtu, LAN $lmtu (LAN client interface: ${lanmtu:-?})"
  for f in bsd opn; do
    [[ -s "$W/vtnet-$f.txt" ]] && { echo; echo "vtnet0 on $f:"; echo '```'; cat "$W/vtnet-$f.txt"; echo '```'; }
  done
  [[ -s "$W/opn-offload.txt" ]] && { echo; echo "OPNsense offload settings:"; echo '```'; cat "$W/opn-offload.txt"; echo '```'; }
} >> "$SUM"
[[ "$SUM" != /dev/stdout ]] && cat "$SUM"
