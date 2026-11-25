#!/bin/sh
# Builds the OPNsense cloud image for OpenStack and Proxmox.
#
# Runs as root on the dedicated FreeBSD runner (build-freebsd-image reusable
# workflow, build_runner input):  sh build/build.sh <version> <out-dir>
# <version> is an OPNsense release, e.g. 26.7.9: the build starts from the
# official nano image of its series (26.7), verified against the series
# signing key pinned in keys/, updates it in a chroot and fails unless the
# core package ends at exactly <version>.
# Produces <out-dir>/image.raw.
#
# OPNsense itself is not modified. The image adds:
#   - a prepared /conf/config.xml for clouds (see build/config.php): WAN on the
#     first NIC (DHCPv4, DHCPv6/SLAAC), optional LAN on the second, SSH with
#     keys only, web GUI reachable on the WAN, /var and /tmp on disk;
#   - os-qemu-guest-agent (official plugin);
#   - the first-boot layer (build/overlay): interfaces matched to the NICs
#     found, then SSH keys, hostname and web GUI password from the config
#     drive, the NoCloud drive (Proxmox) or the metadata service.

set -eu

VERSION="${1:?usage: build.sh <version> <out-dir>}"
OUT="${2:?usage: build.sh <version> <out-dir>}"
SERIES=$(echo "$VERSION" | grep -oE '^[0-9]+\.[0-9]+')
HERE=$(cd "$(dirname "$0")" && pwd)
KEY="$HERE/../keys/OPNsense-${SERIES}.pub"
MIRROR="${OPNSENSE_MIRROR:-https://pkg.opnsense.org/releases}"
IMG="OPNsense-${SERIES}-nano-amd64.img"

[ -f "$KEY" ] || { echo "::error::no signing key for OPNsense $SERIES in keys/" >&2; exit 1; }

work=$(mktemp -d /tmp/oic-opnsense.XXXXXX)
mnt="$work/mnt"
md=""
cleanup() {
  set +e
  for m in "$mnt/var/cache/pkg" "$mnt/dev"; do umount -f "$m" 2>/dev/null; done
  umount -f "$mnt" 2>/dev/null
  [ -n "$md" ] && mdconfig -d -u "$md" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT INT TERM
mkdir -p "$OUT" "$mnt"

echo "[build] OPNsense $VERSION from the $SERIES nano image"

# --- Official image, verified against the pinned series key ----------------
fetch -q -o "$work/$IMG.bz2" "$MIRROR/$SERIES/$IMG.bz2"
fetch -q -o "$work/$IMG.sig" "$MIRROR/$SERIES/$IMG.sig"
openssl base64 -d -in "$work/$IMG.sig" -out "$work/$IMG.sig.bin"
bunzip2 "$work/$IMG.bz2"
openssl dgst -sha256 -verify "$KEY" -signature "$work/$IMG.sig.bin" "$work/$IMG"
echo "[build] signature of $IMG verified"

# --- Grow the image so the in-place upgrade has room -------------------------
# The nano image root is sized for a CF card, not for applying a newer base +
# kernel on top: opnsense-update -bk fills it (26.7.10 overflowed the 3 GB
# image). Grow the file, the BSD partition and the UFS before mounting. The
# published image is re-expanded to the real disk on first boot (the
# .probe.for.growfs marker below), so this only affects the build host.
GROW_GB="${OPNSENSE_IMG_GB:-6}"
echo "[build] growing image to ${GROW_GB} GB for the upgrade"
truncate -s "${GROW_GB}G" "$work/$IMG"

# --- Mount the image ---------------------------------------------------------
md=$(mdconfig -a -t vnode -f "$work/$IMG")
gpart recover "$md" || true
gpart resize -i 1 "$md"
fsck_ufs -y "/dev/${md}a" >/dev/null 2>&1 || true
growfs -y "/dev/${md}a"
mount "/dev/${md}a" "$mnt"
df -h "$mnt" | sed 's/^/[build] /'
mount -t devfs devfs "$mnt/dev"
cp /etc/resolv.conf "$mnt/etc/resolv.conf"

# --- Update to the requested release, add the guest agent plugin -----------
# pkg upgrades the core and plugins; opnsense-update -bk brings base and
# kernel to the same release (it reads their versions from the image, not
# from the build host kernel).
cat > "$mnt/tmp/oic-update.sh" <<'UPDATE'
#!/bin/sh
set -eu
export ASSUME_ALWAYS_YES=yes PAGER=cat
pkg update -f
pkg upgrade -y
opnsense-update -bk || opnsense-update -bk
pkg install -y os-qemu-guest-agent
pkg clean -ay
UPDATE
chmod +x "$mnt/tmp/oic-update.sh"
chroot "$mnt" /tmp/oic-update.sh

core=$(chroot "$mnt" /usr/local/sbin/opnsense-version -v core)
echo "[build] core $core, base $(chroot "$mnt" /usr/local/sbin/opnsense-version -v base), kernel $(chroot "$mnt" /usr/local/sbin/opnsense-version -v kernel)"
case "$core" in
  "$VERSION"|"$VERSION"_*) ;;
  *) echo "::error::OPNsense core is $core after the update, expected $VERSION" >&2; exit 1 ;;
esac

# --- Cloud configuration and first-boot layer --------------------------------
cp "$HERE/config.php" "$mnt/tmp/oic-config.php"
chroot "$mnt" /usr/local/bin/php /tmp/oic-config.php
(cd "$HERE/overlay" && find . -type f) | while read -r f; do
  mkdir -p "$(dirname "$mnt/${f#./}")"
  install -m 0755 "$HERE/overlay/$f" "$mnt/${f#./}"
done
touch "$mnt/.probe.for.growfs"

# --- Clean up ------------------------------------------------------------------
rm -f "$mnt/tmp/oic-update.sh" "$mnt/tmp/oic-config.php" "$mnt/etc/resolv.conf"
rm -rf "$mnt/var/cache/pkg/"* "$mnt/var/db/pkg/repos/"* "$mnt/tmp/"* "$mnt/var/tmp/"*
rm -f "$mnt"/etc/ssh/ssh_host_* "$mnt/etc/hostid" "$mnt/root/.history"
# Package scripts may have left daemons running in the chroot (configd):
# stop whatever still holds files in the image before unmounting it.
stop_chroot_procs() {
  for pid in $(fstat -f "$mnt" 2>/dev/null | awk 'NR > 1 { print $3 }' | sort -u); do
    echo "[build] stopping $(ps -o comm= -p "$pid" 2>/dev/null) (pid $pid) left in the chroot"
    kill "$pid" 2>/dev/null
  done
  sleep 2
  for pid in $(fstat -f "$mnt" 2>/dev/null | awk 'NR > 1 { print $3 }' | sort -u); do
    kill -9 "$pid" 2>/dev/null
  done
}
stop_chroot_procs
umount "$mnt/dev" || { stop_chroot_procs; umount -f "$mnt/dev"; }
umount "$mnt"
mdconfig -d -u "$md"; md=""

mv "$work/$IMG" "$OUT/image.raw"
echo "[build] done: $OUT/image.raw"
