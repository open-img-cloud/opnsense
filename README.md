<p align="center">
  <a href="https://openimages.cloud/images/opnsense/">
    <img src="https://openimages.cloud/img/og/opnsense.png" alt="OPNsense firewall image for OpenStack and Proxmox" width="720">
  </a>
</p>

<p align="center">
  <a href="https://openimages.cloud/images/opnsense/"><img alt="Latest version" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fimages.openimages.cloud%2Fopnsense%2Flatest%2FMANIFEST.json&query=%24.version&label=latest&color=2459c4&cacheSeconds=3600"></a>
  <a href="https://github.com/open-img-cloud/opnsense/actions/workflows/release.yml"><img alt="Release" src="https://github.com/open-img-cloud/opnsense/actions/workflows/release.yml/badge.svg"></a>
  <a href="https://openimages.cloud/verify/"><img alt="Signed with Sigstore cosign" src="https://img.shields.io/badge/signed-Sigstore%20cosign-2459c4"></a>
  <a href="https://openimages.cloud/quality/"><img alt="Boot-tested on OpenStack" src="https://img.shields.io/badge/boot--tested-OpenStack-2459c4"></a>
  <a href="LICENSE.md"><img alt="License BSD-2-Clause" src="https://img.shields.io/badge/license-BSD--2--Clause-555"></a>
</p>

<p align="center">
  <a href="https://openimages.cloud/images/opnsense/"><b>Catalog page</b></a> ·
  <a href="https://images.openimages.cloud/opnsense/latest/">Download</a> ·
  <a href="https://openimages.cloud/verify/">Verify</a> ·
  <a href="https://github.com/open-img-cloud/docs">Documentation</a> ·
  <a href="https://github.com/open-img-cloud/opnsense/issues">Report an issue</a>
</p>

> **Community image.** Not an official OPNsense or Deciso product. OPNsense is a trademark
> of Deciso B.V.; this project is not affiliated with it. Official images and commercial
> offers: [opnsense.org](https://opnsense.org/).

OPNsense firewall image (qcow2) ready to boot unattended on **OpenStack** and **Proxmox VE**:
built from the official, signed OPNsense nano image, updated to the current release with its
hotfix level, with a small first-boot layer that applies the instance metadata (there is no
cloud-init on OPNsense). Signed with Sigstore cosign and boot-tested on a real OpenStack before
it is published, like every [openimages.cloud](https://openimages.cloud) image.

## At a glance

| | |
|---|---|
| **Upstream** | Official `OPNsense-<series>-nano-amd64.img`, verified against the series key pinned in [`keys/`](keys), updated with `pkg` and `opnsense-update` to the release in [`VERSION`](VERSION) |
| **Catalog id** | `opnsense`, the current OPNsense series |
| **Login** | `root`: SSH with your key, web interface and console with a password ([below](#2-get-the-password-of-the-web-interface)) |
| **Network** | WAN on the first NIC (DHCPv4, DHCPv6/SLAAC); LAN on the second NIC when there is one (OPNsense defaults: 192.168.1.1/24, DHCP server) |
| **Web interface** | `https://<WAN address>/`, open on the WAN after boot |
| **Firmware** | BIOS |
| **Format** | qcow2, x86_64, UFS root grown to the disk at first boot |
| **Version** | OPNsense release and hotfix level, e.g. `26.7.9_3` ([all versions](https://images.openimages.cloud/opnsense/versions.json)) |

## Quick start

```sh
# Latest version and its file name, from the signed manifest
M=https://images.openimages.cloud/opnsense/latest/MANIFEST.json
V=$(curl -fsS $M | jq -r .version); F=$(curl -fsS $M | jq -r .filename)
curl -fLO https://images.openimages.cloud/opnsense/$V/$F
```

<details>
<summary><b>OpenStack</b></summary>

```sh
openstack image create --disk-format qcow2 --container-format bare \
  --property os_distro=freebsd --property hw_qemu_guest_agent=yes \
  --property os_admin_user=root \
  --file "$F" "OPNsense $V"

# One NIC: WAN only. Add a second network for a LAN.
openstack server create --image "OPNsense $V" --flavor <2 vCPU, 4 GB> \
  --network <wan-net> --key-name <rsa-key> opnsense
```

Use an RSA key if you want `nova get-password` (below). The full property set is on the
[catalog page](https://openimages.cloud/images/opnsense/) and in
[`index.json`](https://images.openimages.cloud/index.json).

</details>

<details>
<summary><b>Proxmox VE</b></summary>

The commands to create a template from this image are on the
[catalog page](https://openimages.cloud/images/opnsense/). The Proxmox cloud-init drive
(NoCloud) is read: *Cloud-Init > SSH public key*, *Password* and the VM name apply.

</details>

<details>
<summary><b>Verify the signature</b></summary>

```sh
curl -fLO https://images.openimages.cloud/opnsense/$V/$F.bundle
cosign verify-blob "$F" --bundle "$F.bundle" \
  --certificate-identity-regexp '^https://github.com/open-img-cloud/\.github/\.github/workflows/build-(libguestfs|dib|nix-flake|freebsd)-image\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

</details>

## After deployment

### 1. Restrict who can reach the instance

The web interface (443) and SSH (22) are open on the WAN so the appliance is reachable right
after boot. Limit them to your addresses in the OpenStack security group or the Proxmox
firewall.

### 2. Get the password of the web interface

The password of `root` (web interface and console) comes from the first of these that
applies; if one fails, the next one still works:

1. **The one you set at deployment**, in the user data:
   ```yaml
   #cloud-config
   password: choose-a-long-password
   ```
   On Proxmox, fill in *Cloud-Init > Password*: Proxmox passes it hashed and it works as is.
   This password is never printed anywhere.
2. **Otherwise a generated one** (24 characters), on the first instance:
   - with your RSA key on OpenStack: `nova get-password <server> ~/.ssh/id_rsa`
     (available a minute or two after boot);
   - on the serial console, any key type and on Proxmox:
     `openstack console log show <server>`, or the console of the VM.
3. **At any time with your SSH key**: `ssh root@<address>`, then option 3 of the menu
   (*Reset the root password*), or `opnsense-shell password`.

Change it after the first login (*System: Access: Users*).

### 3. Log in

Open `https://<WAN address>/` (self-signed certificate) and log in as `root`.

## Network performance on virtio-net

OPNsense is FreeBSD, and FreeBSD on virtio-net (`vtnet`) is slower than Linux, mostly when
receiving. Size the instance with that in mind. Measured on Infomaniak public cloud
(2 vCPU flavor, iperf3, November 2026, OPNsense 26.7, Debian 13 VMs at both ends):

| Mbit/s, 4 streams | LAN to WAN | WAN to LAN |
|---|---|---|
| Linux VM to Linux VM, no firewall (the cloud's ceiling for this flavor) | 2290 | 2280 |
| Routed and NATed by OPNsense, offloads off (image default) | 690 to 1130 | 720 to 1720 |
| Same, offloads on, client on another hypervisor host | 1150 to 1340 | 690 to 1700 |
| Same, offloads on, client on the **same** hypervisor host as OPNsense | **580** | **380** |

Figures vary with the hypervisor host from one run to the next. What follows from them:

- **Leave the offloads off** (*Interfaces: Settings*: hardware CRC, TSO and LRO disabled,
  the OPNsense default and this image's). Turning checksum and TSO on does not speed up
  routing to other hosts, and **halves** it when the LAN clients run on the same hypervisor
  host as OPNsense, which is common in a cloud. This is a known FreeBSD issue with checksum
  offload on virtio-net when forwarding
  ([FreeBSD bug 165059](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=165059),
  [OPNsense forum](https://forum.opnsense.org/index.php?topic=45870.0)); on some KVM clouds
  it breaks forwarding entirely.
- The offloads only help traffic that ends on the firewall itself (VPN termination, proxy,
  web interface): 1.3 to 1.4 instead of 0.6 to 0.7 Gbit/s here (4 streams sent). Turn them on only if that is your
  main use and your LAN clients never share a host with OPNsense.
- **Keep multiqueue on** (`hw_vif_multiqueue_enabled=true`, in the catalog properties):
  FreeBSD then uses one queue pair per vCPU. More vCPUs raise the routed throughput with
  several flows, not with a single one.
- Packet filtering itself is not the bottleneck: disabling pf changes nothing.

The measurement is reproducible with [`tests/throughput.sh`](tests/throughput.sh)
(workflow *Throughput (Infomaniak)*; `scope=opnsense` forces the same-host case with an
affinity server group).

## What this image contains

[`build/build.sh`](build/build.sh) runs on a dedicated FreeBSD runner. OPNsense itself is not
modified:

- the official nano image of the series, its signature checked against the pinned key, then
  `pkg upgrade` and `opnsense-update -bk` to the release in the version; the build fails if
  the core package ends at another release;
- the official `os-qemu-guest-agent` plugin;
- a prepared configuration ([`build/config.php`](build/config.php)): `/var` and `/tmp` on
  disk instead of memory, no initial wizard (it would reassign the interfaces), WAN without
  the private and bogon network blocks (in a cloud the WAN is on a private tenant network),
  rules on the WAN for the web interface, SSH and ping to the firewall, DNS rebinding and
  HTTP referer checks off (access through a floating IP or NAT), SSH with keys only;
  the NIC offloads stay off as OPNsense ships them ([below](#network-performance-on-virtio-net));
- the public default password never works: the root password is random until the first-boot
  layer sets it;
- the first-boot layer ([`build/overlay`](build/overlay)): at every boot, before OPNsense
  configures the system, the WAN and LAN are matched to the NICs found, so the boot never
  stops at the interactive interface assignment. Once per instance it reads the config drive
  (`config-2`), the NoCloud drive (`cidata`, Proxmox) or the OpenStack metadata service and
  sets the SSH keys of `root`, the hostname and the password as described above. It logs its
  steps, never a password, to `/var/log/oic-firstboot.log`.

Every release must pass the [runtime contract](https://openimages.cloud/quality/) for network
appliances on OpenStack: SSH with the injected key, first-boot layer finished, DNS, hostname,
root filesystem grown, guest agent, web interface reachable from the Internet, the generated
password readable with `nova get-password` and identical on the serial console, IPv6 address
and egress.

## How releases happen

1. Every day at 07:41 UTC a watcher reads the version of the OPNsense core package for the
   current series and opens a pull request that bumps [`VERSION`](VERSION) when a release or
   hotfix comes out. A new series (27.1 in January) needs its signing key reviewed and added
   to [`keys/`](keys) first.
2. Merging it is all it takes: the release is tagged, then the image is built, signed,
   boot-tested and published, and `latest/` and the
   [catalog](https://openimages.cloud/images/) move to it.

## License

The build tooling in this repository is under the [BSD 2-Clause license](LICENSE.md), like
OPNsense. The image keeps the licensing terms of OPNsense and of the packages it contains.
OPNsense is a trademark of Deciso B.V.; this project is not affiliated with it.
