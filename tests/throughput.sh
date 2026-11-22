#!/usr/bin/env bash
# Network throughput on OpenStack (virtio-net) of the published images, with
# the vtnet offload and pf variations that explain the differences.
#
#   tests/throughput.sh            (OS_* credentials in the environment)
#
# VMs, all from the published catalog files:
#   srv   Debian 13 on the public network: iperf3 server, the far end of every test
#   deb   Debian 13 client: Linux baseline
#   bsd   FreeBSD 15 client
#   opn   OPNsense: WAN on the public network, LAN on a private 192.168.1.0/24
#   lan   Debian 13 on that LAN only (static address from the config drive):
#         its traffic is routed and NATed by opn; driven over SSH through opn
# SCOPE=opnsense (default all) only boots srv, opn, lan and srvh: OPNsense,
# the LAN client and srvh (a second server) share one hypervisor host
# (affinity server group), the case where checksum offload is known to break
# forwarding on vtnet (FreeBSD PR 165059). OPN_IMAGE_FILE=<qcow2> tests a
# local OPNsense build instead of the published one.
# Each case is iperf3 against srv for 10 s: 1 and 4 streams, upload and
# download (-R). Results go to $GITHUB_STEP_SUMMARY when set.
set -uo pipefail

CDN=https://images.openimages.cloud
FLAVOR=${FLAVOR:-a2-ram4-disk20-perf1}
EXTNET=${EXTNET:-ext-net1}
DUR=${DUR:-10}
T=oic-perf-${GITHUB_RUN_ID:-local}
W=$(mktemp -d)
SUM=${GITHUB_STEP_SUMMARY:-/dev/stdout}
O=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes -i "$W/id")
LANIP=192.168.1.50
SCOPE=${SCOPE:-all}
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

cleanup() {
  set +e
  log "cleanup"
  for s in srv srvh deb bsd opn lan; do openstack server delete --wait "$T-$s" 2>/dev/null; done
  for p in opn-lan lan; do openstack port delete "$T-$p" 2>/dev/null; done
  openstack subnet delete "$T-lan" 2>/dev/null
  openstack network delete "$T-lan" 2>/dev/null
  for i in debian bsd opn; do openstack image delete "$T-$i" 2>/dev/null; done
  openstack keypair delete "$T" 2>/dev/null
  openstack server group delete "$T" 2>/dev/null
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
  local m f v
  m=$(curl -fsS -A oic-check "$CDN/$1/latest/MANIFEST.json")
  f=$(jq -r .filename <<<"$m"); v=$(jq -r .version <<<"$m")
  log "image $1 $v"
  echo "$1 $v" >> "$W/versions"
  curl -fsSL -A oic-check -o "$W/$f" "$CDN/$1/$v/$f"
  openstack image create --disk-format qcow2 --container-format bare --file "$W/$f" \
    --property hw_qemu_guest_agent=yes --property hw_vif_multiqueue_enabled=true \
    "$2" >/dev/null
  rm -f "$W/$f"
}
image debian-13 "$T-debian"
[[ $SCOPE == all ]] && image freebsd-15 "$T-bsd"
if [[ -n "${OPN_IMAGE_FILE:-}" ]]; then
  log "image opnsense from $OPN_IMAGE_FILE (unpublished build)"
  echo "opnsense $(basename "$OPN_IMAGE_FILE") (unpublished build)" >> "$W/versions"
  openstack image create --disk-format qcow2 --container-format bare --file "$OPN_IMAGE_FILE" \
    --property hw_qemu_guest_agent=yes --property hw_vif_multiqueue_enabled=true "$T-opn" >/dev/null
else
  image opnsense "$T-opn"
fi

# --- LAN behind OPNsense -------------------------------------------------------
# No Neutron DHCP: the client takes its static address from the config drive,
# OPNsense is the gateway and the DNS resolver.
openstack network create "$T-lan" >/dev/null
openstack subnet create --network "$T-lan" --subnet-range 192.168.1.0/24 --no-dhcp \
  --gateway 192.168.1.1 --dns-nameserver 192.168.1.1 "$T-lan" >/dev/null
openstack port create --network "$T-lan" --fixed-ip subnet="$T-lan",ip-address=192.168.1.1 \
  --disable-port-security --no-security-group "$T-opn-lan" >/dev/null
openstack port create --network "$T-lan" --fixed-ip subnet="$T-lan",ip-address=$LANIP \
  --disable-port-security --no-security-group "$T-lan" >/dev/null

# --- servers ---------------------------------------------------------------------
cat > "$W/srv.yaml" <<'EOF'
#cloud-config
packages: [iperf3]
runcmd:
  - [sh, -c, "iperf3 -s -D"]
EOF
cat > "$W/client.yaml" <<'EOF'
#cloud-config
packages: [iperf3]
EOF
boot() { # <name> <image> [extra args]
  local n=$1 i=$2; shift 2
  openstack server create --flavor "$FLAVOR" --image "$T-$i" --key-name "$T" "$@" "$T-$n" >/dev/null \
    && log "boot $n" || log "boot $n FAILED"
}
boot srv debian --network "$EXTNET" --security-group "$T" --user-data "$W/srv.yaml"
if [[ $SCOPE == all ]]; then
  boot deb debian --network "$EXTNET" --security-group "$T" --user-data "$W/client.yaml"
  boot bsd bsd --network "$EXTNET" --security-group "$T"
fi
AFF=$(openstack server group create --policy affinity -f value -c id "$T")
boot srvh debian --network "$EXTNET" --security-group "$T" --user-data "$W/srv.yaml" --hint group="$AFF"
boot opn opn --hint group="$AFF" --nic net-id="$(openstack network show -f value -c id "$EXTNET")" \
  --nic port-id="$(openstack port show -f value -c id "$T-opn-lan")" --security-group "$T"
boot lan debian --hint group="$AFF" --nic port-id="$(openstack port show -f value -c id "$T-lan")" \
  --config-drive true --user-data "$W/client.yaml"

ip4() { openstack server show -f json -c addresses "$1" | jq -r '[.addresses[][]] | map(select(test("^[0-9.]+$")))[0]'; }
waitssh() { # <user@ip>
  for _ in $(seq 1 60); do ssh "${O[@]}" "$1" true </dev/null 2>/dev/null && return 0; sleep 10; done
  return 1
}
for _ in $(seq 1 60); do
  [[ "$(openstack server list --name "^$T-" -f value -c Status | sort -u)" == ACTIVE ]] && break; sleep 5
done
SRV=$(ip4 "$T-srv"); SRVH=$(ip4 "$T-srvh"); OPN=$(ip4 "$T-opn")
[[ $SCOPE == all ]] && { DEB=$(ip4 "$T-deb"); BSD=$(ip4 "$T-bsd"); }
log "srv $SRV srvh $SRVH deb ${DEB:-} bsd ${BSD:-} opn $OPN lan $LANIP"
# hypervisor placement (hashed host ids): srvh, opn and lan must share one
{ echo "## Placement (hostId)"
  for n in srv srvh opn lan; do echo "$n $(openstack server show -f value -c hostId "$T-$n" | cut -c1-12)"; done
} >> "$W/state"

for h in "$SRV" "$SRVH"; do
  waitssh "debian@$h" || log "$h: no SSH"
  for _ in $(seq 1 30); do ssh "${O[@]}" "debian@$h" 'pgrep -x iperf3' </dev/null >/dev/null 2>&1 && break; sleep 10; done
done

# --- helpers -------------------------------------------------------------------
# on <target> <script>: run a POSIX sh script on a client (root's login shell
# on OPNsense is a menu or csh: always go through sh -s)
on() { ssh "${O[@]}" "$1" "sh -s" <<<"PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
$2"; }
# on the LAN client, through OPNsense (no TCP forwarding needed)
LANSSH="ssh -i /tmp/oic-perf-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes debian@$LANIP"
onlan() { on "root@$OPN" "$LANSSH 'sh -s' <<'LANEOF'
$1
LANEOF"; }

# cases <label> <runner function>: the 4 iperf3 cases
cases() {
  local label=$1 fn=$2 a r
  for a in "-P 1" "-P 4" "-P 1 -R" "-P 4 -R"; do
    r=$($fn "iperf3 -c ${TGT:-$SRV} -t $DUR $a -J" 2>/dev/null \
      | jq -r '(.end.sum_received.bits_per_second // 0) / 1e6 | floor' 2>/dev/null)
    [[ "$r" =~ ^[1-9][0-9]*$ ]] || r=fail
    echo "$label|$a|$r" >> "$W/results"
    log "$label $a: $r"
  done
  echo "$label" >> "$W/order"
}
run_deb() { on "debian@$DEB" "$1"; }
run_bsd() { on "freebsd@$BSD" "$1"; }
run_opn() { on "root@$OPN" "$1"; }
run_lan() { onlan "$1"; }
vtnet() { # <label> <target> <ifaces>
  { echo "## $1"; on "$2" "for i in $3; do ifconfig \$i | sed -n '1p;/options=/p'; done; sysctl -n dev.vtnet.0.act_vq_pairs | sed 's/^/vtnet0 active queue pairs: /'"; } >> "$W/state" 2>&1
}
OFF6="-rxcsum -txcsum -tso -lro -rxcsum6 -txcsum6"
ON6="rxcsum txcsum tso lro rxcsum6 txcsum6"

# --- Debian baseline -------------------------------------------------------------
if [[ $SCOPE == all ]] && waitssh "debian@$DEB"; then
  for _ in $(seq 1 30); do on "debian@$DEB" 'command -v iperf3' >/dev/null 2>&1 && break; sleep 10; done
  cases "Debian 13" run_deb
fi

# --- FreeBSD 15: as shipped, LRO off, all offloads off ------------------------------
if [[ $SCOPE == all ]] && waitssh "freebsd@$BSD"; then
  on "freebsd@$BSD" 'sudo env ASSUME_ALWAYS_YES=yes pkg install -y iperf3' >/dev/null 2>&1
  vtnet "FreeBSD 15 as shipped" "freebsd@$BSD" vtnet0
  cases "FreeBSD 15 as shipped" run_bsd
  on "freebsd@$BSD" 'sudo ifconfig vtnet0 -lro; sleep 2'
  cases "FreeBSD 15, LRO off" run_bsd
  on "freebsd@$BSD" "sudo ifconfig vtnet0 $OFF6; sleep 2"
  cases "FreeBSD 15, all offloads off" run_bsd
fi

# --- OPNsense: host, then routed for the LAN client -------------------------------
if waitssh "root@$OPN"; then
  on "root@$OPN" 'env ASSUME_ALWAYS_YES=yes pkg install -y iperf3' >/dev/null 2>&1
  { echo "## OPNsense offload settings (config.xml)"
    on "root@$OPN" 'php -r '\''require_once "config.inc"; foreach (["disablechecksumoffloading","disablesegmentationoffloading","disablelargereceiveoffloading"] as $k) echo "$k=", ($config["OPNsense"]["Interfaces"]["settings"][$k] ?? "default (1)"), "\n";'\'''
  } >> "$W/state" 2>&1
  vtnet "OPNsense as shipped" "root@$OPN" "vtnet0 vtnet1"
  # key for the LAN hop
  on "root@$OPN" "umask 077; cat > /tmp/oic-perf-key <<'KEY'
$(cat "$W/id")
KEY"
  lan_ok=no
  for _ in $(seq 1 40); do onlan 'command -v iperf3' >/dev/null 2>&1 && { lan_ok=yes; break; }; sleep 10; done
  if [[ $lan_ok == no ]]; then
    { echo "## LAN client diagnostics (no iperf3 after 7 minutes)"
      onlan 'ip -4 addr show scope global; ip route; cat /etc/resolv.conf; ping -c2 -W2 192.168.1.1; ping -c2 -W2 '"$SRV"'; getent hosts deb.debian.org; sudo tail -5 /var/log/cloud-init-output.log' 2>&1 | head -40
      echo "### OPNsense side"; on "root@$OPN" 'ifconfig vtnet1 | head -5; pfctl -s nat 2>/dev/null | head -5; ping -c2 -W2 '"$LANIP" 2>&1 | head -20
    } >> "$W/state"
  fi

  # As built: the image under test decides the offloads. Then all offloads off.
  # Routed cases to srv (anywhere) and to srvh (same hypervisor host as OPNsense
  # and the LAN client: the PR 165059 case).
  for mode in "as built" "offloads off"; do
    if [[ $mode == "offloads off" ]]; then
      on "root@$OPN" "ifconfig vtnet0 $OFF6; ifconfig vtnet1 $OFF6; sleep 3"
    fi
    vtnet "OPNsense, $mode" "root@$OPN" "vtnet0 vtnet1"
    cases "OPNsense host, $mode" run_opn
    if [[ $lan_ok == yes ]]; then
      cases "Through OPNsense, $mode, to another host" run_lan
      TGT=$SRVH cases "Through OPNsense, $mode, same host" run_lan
    fi
  done
else log "opn: no SSH"; fi

# --- report --------------------------------------------------------------------
{
  echo "## Throughput on Infomaniak ($OS_REGION_NAME, $FLAVOR, ${DUR}s iperf3 to a Debian 13 server), Mbit/s"
  echo
  echo "Images: $(tr '\n' ' ' < "$W/versions"). Network MTU: $EXTNET $(openstack network show -f value -c mtu "$EXTNET" 2>/dev/null)."
  echo
  echo "| Client | 1 stream up | 4 streams up | 1 stream down | 4 streams down |"
  echo "|---|---|---|---|---|"
  while read -r c; do
    row="| $c"
    for a in "-P 1" "-P 4" "-P 1 -R" "-P 4 -R"; do
      row="$row | $(grep -F "$c|$a|" "$W/results" | head -1 | cut -d'|' -f3)"
    done
    echo "$row |"
  done < "$W/order"
  echo
  echo '```'
  cat "$W/state" 2>/dev/null
  echo '```'
} >> "$SUM"
[[ "$SUM" != /dev/stdout ]] && cat "$SUM"
