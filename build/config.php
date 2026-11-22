<?php
/*
 * Prepares /conf/config.xml for clouds. Runs once at build time in a chroot of
 * the image (build/build.sh), on OPNsense's own default configuration.
 *
 * - WAN on vtnet0 (DHCPv4 and DHCPv6), LAN on vtnet1 with the OPNsense
 *   defaults; the early first-boot hook matches them to the NICs found.
 * - No private/bogon blocking on the WAN: in a cloud the WAN sits on a
 *   private tenant network.
 * - Web GUI reachable on the WAN (rules for 443 and 22 to the firewall), with
 *   the DNS rebinding and referer checks off: the GUI is reached through a
 *   floating IP or a NAT address that is not on any interface.
 * - SSH enabled, root login with keys only (password logins off).
 * - root password replaced by an unknown random one: the first-boot layer
 *   sets the real one (user data, else generated). The public default
 *   password never works on this image.
 * - /var and /tmp on disk (the nano image keeps them in memory for flash
 *   media), no initial wizard (it reassigns the interfaces).
 * - QEMU guest agent plugin enabled.
 */

$src = '/usr/local/etc/config.xml';
$dst = '/conf/config.xml';

$doc = new DOMDocument();
$doc->preserveWhiteSpace = false;
$doc->formatOutput = true;
if (!$doc->load($src)) {
    fwrite(STDERR, "cannot load $src\n");
    exit(1);
}
$xp = new DOMXPath($doc);
$root = $doc->documentElement;

function node(DOMXPath $xp, string $path): DOMElement
{
    $found = $xp->query($path);
    if ($found->length !== 1) {
        fwrite(STDERR, "expected one node at $path, found {$found->length}\n");
        exit(1);
    }
    return $found->item(0);
}

function drop(DOMXPath $xp, string $path): void
{
    foreach (iterator_to_array($xp->query($path)) as $n) {
        $n->parentNode->removeChild($n);
    }
}

function child(DOMDocument $doc, DOMElement $parent, string $name, ?string $value = null): DOMElement
{
    foreach ($parent->childNodes as $c) {
        if ($c instanceof DOMElement && $c->nodeName === $name) {
            if ($value !== null) {
                $c->nodeValue = $value;
            }
            return $c;
        }
    }
    $c = $doc->createElement($name);
    if ($value !== null) {
        $c->appendChild($doc->createTextNode($value));
    }
    $parent->appendChild($c);
    return $c;
}

function xml_fragment(DOMDocument $doc, DOMElement $parent, string $xml): void
{
    $f = $doc->createDocumentFragment();
    $f->appendXML($xml);
    $parent->appendChild($f);
}

drop($xp, '/opnsense/trigger_initial_wizard');
drop($xp, '/opnsense/system/use_mfs_tmp');
drop($xp, '/opnsense/system/use_mfs_var');

$system = node($xp, '/opnsense/system');

/* root: unknown random password until the first-boot layer sets one */
node($xp, "/opnsense/system/user[uid='0']/password")->nodeValue =
    password_hash(bin2hex(random_bytes(32)), PASSWORD_BCRYPT, ['cost' => 11]);

/* SSH: root with keys only */
$ssh = node($xp, '/opnsense/system/ssh');
child($doc, $ssh, 'enabled', 'enabled');
child($doc, $ssh, 'permitrootlogin', '1');
drop($xp, '/opnsense/system/ssh/passwordauth');

/* Web GUI over HTTPS, reachable through floating IPs and NAT */
$webgui = node($xp, '/opnsense/system/webgui');
child($doc, $webgui, 'protocol', 'https');
child($doc, $webgui, 'nodnsrebindcheck', '1');
child($doc, $webgui, 'nohttpreferercheck', '1');

/* Interfaces: WAN first NIC, LAN second NIC */
$wan = node($xp, '/opnsense/interfaces/wan');
child($doc, $wan, 'if', 'vtnet0');
drop($xp, '/opnsense/interfaces/wan/blockpriv');
drop($xp, '/opnsense/interfaces/wan/blockbogons');
child($doc, node($xp, '/opnsense/interfaces/lan'), 'if', 'vtnet1');

/* Filter (MVC rules, as in the default config): SSH, web GUI and ping to the
 * firewall itself on the WAN. The security group restricts the sources. */
function uuid4(): string
{
    $b = random_bytes(16);
    $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
    $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
    return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($b), 4));
}
$rules = node($xp, '/opnsense/OPNsense/Firewall/Filter/rules');
$seq = 100;
foreach ([['TCP', '443', 'web GUI', 'inet46'], ['TCP', '22', 'SSH', 'inet46'], ['ICMP', '', 'ping', 'inet']] as [$proto, $port, $what, $family]) {
    xml_fragment($doc, $rules, sprintf(
        '<rule uuid="%s"><enabled>1</enabled><statetype>keep</statetype><state-policy/>' .
        '<sequence>%d</sequence><action>pass</action><quick>1</quick><interfacenot>0</interfacenot>' .
        '<interface>wan</interface><direction>in</direction><ipprotocol>%s</ipprotocol>' .
        '<protocol>%s</protocol><source_net>any</source_net><source_not>0</source_not><source_port/>' .
        '<destination_net>(self)</destination_net><destination_not>0</destination_not>' .
        '<destination_port>%s</destination_port><disablereplyto>0</disablereplyto><log>0</log>' .
        '<allowopts>0</allowopts><nosync>0</nosync><nopfsync>0</nopfsync><statetimeout/>' .
        '<tcpflags_any>0</tcpflags_any>' .
        '<description>openimages.cloud: %s to the firewall on the WAN (restrict the source in your security group)</description></rule>',
        uuid4(), $seq, $family, $proto, $port, $what
    ));
    $seq += 10;
}

/* QEMU guest agent plugin */
$opn = node($xp, '/opnsense/OPNsense');
xml_fragment($doc, $opn, '<QemuGuestAgent version="1.0.0"><general><Enabled>1</Enabled><LogDebug>0</LogDebug><DisabledRPCs/></general></QemuGuestAgent>');

/*
 * NIC offloads: left as OPNsense ships them (all disabled). Enabling checksum
 * and TSO on virtio-net does not speed up routing to other hosts and halves
 * it between VMs on the same hypervisor host (measured on Infomaniak, see the
 * README and tests/throughput.sh); it only helps traffic ending on the firewall.
 */

@mkdir('/conf', 0755);
if ($doc->save($dst) === false) {
    fwrite(STDERR, "cannot write $dst\n");
    exit(1);
}
chmod($dst, 0644);
/* the first-boot layer generates a password only while this marker exists */
touch('/conf/oic-password-unset');
echo "[config] $dst prepared for clouds\n";
