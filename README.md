# OPNsense cloud image for OpenStack and Proxmox

> **Work in progress, not published.** This community image is not an official
> OPNsense or Deciso product. OPNsense is a trademark of Deciso B.V.; the name
> is used here pending their permission. Official images and commercial
> offers: [opnsense.org](https://opnsense.org/).

OPNsense (qcow2, x86_64) ready to boot unattended on **OpenStack** and
**Proxmox VE**: built from the official, signed OPNsense nano image, updated to
the current release, with a small first-boot layer that applies the instance
metadata (no cloud-init on OPNsense). Signed with Sigstore cosign and
boot-tested before each release, like every [openimages.cloud](https://openimages.cloud)
image.

## At a glance

| | |
|---|---|
| **Upstream** | Official `OPNsense-<series>-nano-amd64.img`, verified against the series key pinned in [`keys/`](keys), updated with `pkg` and `opnsense-update` to the release in [`VERSION`](VERSION) |
| **Login** | `root`: SSH with your key, web interface and console with a password (below) |
| **Network** | WAN on the first NIC (DHCPv4, DHCPv6/SLAAC); LAN on the second NIC when there is one (OPNsense defaults: 192.168.1.1/24, DHCP server) |
| **Web interface** | `https://<WAN address>/`, open on the WAN by default |
| **Firmware** | BIOS |
| **Format** | qcow2, UFS root grown to the disk at first boot |
| **Version** | OPNsense release with its hotfix level, e.g. `26.7.9_3` |

## After deployment

### 1. Restrict who can reach the instance

The web interface (443) and SSH (22) are open on the WAN so the appliance is
reachable right after boot. Limit them to your addresses in the OpenStack
security group or the Proxmox firewall.

### 2. Get the password of the web interface

The password of `root` (web interface and console) comes from the first of
these that applies; if one fails, the next one still works:

1. **The one you set at deployment**, in the user data:
   ```yaml
   #cloud-config
   password: choose-a-long-password
   ```
   On Proxmox, fill in *Cloud-Init > Password*: Proxmox passes it hashed and
   it works as is. This password is never printed anywhere.
2. **Otherwise a generated one** (24 characters), on the first instance:
   - with your RSA key on OpenStack: `nova get-password <server> ~/.ssh/id_rsa`;
   - on the serial console, any key type and on Proxmox:
     `openstack console log show <server>`, or the console of the VM.
3. **At any time with your SSH key**: `ssh root@<address>`, then option 3 of
   the menu (*Reset the root password*), or `opnsense-shell password`.

Change it after the first login (*System: Access: Users*).

### 3. Log in

Open `https://<WAN address>/` (self-signed certificate) and log in as `root`.

## What the first-boot layer does

At every boot, before OPNsense configures the system, the WAN and LAN are
matched to the NICs found, so the boot never stops at the interactive
interface assignment. Once per instance, after the network is up, it reads
the config drive (`config-2`), the NoCloud drive (`cidata`, Proxmox) or the
OpenStack metadata service and sets:

- the SSH keys of `root` (SSH accepts keys only);
- the hostname;
- the password, as described above.

It logs its steps, never a password, to `/var/log/oic-firstboot.log`.

## Differences from the official nano image

- `/var` and `/tmp` on disk instead of memory;
- no initial wizard (it would reassign the interfaces);
- WAN without the private and bogon network blocks (in a cloud the WAN is on
  a private tenant network);
- rules on the WAN for the web interface, SSH and ping to the firewall, with
  the DNS rebinding and HTTP referer checks off (access through a floating
  IP or NAT);
- the public default password never works: the root password is random until
  the first-boot layer sets it;
- the official `os-qemu-guest-agent` plugin.

## How releases happen

Every day a watcher reads the version of the OPNsense core package for the
current series and opens a pull request that bumps [`VERSION`](VERSION). A
new series (27.1 in January) needs its signing key reviewed and added to
[`keys/`](keys) first.

## License

The build tooling in this repository is under the BSD 2-Clause license, like
OPNsense. The image keeps the licensing terms of OPNsense and of the packages
it contains.
