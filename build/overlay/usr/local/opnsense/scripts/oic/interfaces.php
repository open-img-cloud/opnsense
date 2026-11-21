<?php
/*
 * openimages.cloud: runs at every boot (early syshook), before rc.bootup.
 *
 * The image ships WAN on vtnet0 and LAN on vtnet1. When a configured NIC does
 * not exist on this instance (another NIC model, a single NIC), the WAN moves
 * to the first NIC found and the LAN to the second; without a second NIC the
 * LAN is removed (with the services bound to it), so OPNsense never waits for
 * the interactive interface assignment. Nothing changes when every
 * configured NIC exists.
 */

require_once 'config.inc';
require_once 'util.inc';

$skip = '/^(lo|pflog|pfsync|enc|gif|gre|lagg|vlan|bridge|tap|tun|ovpn|wg|carp|ipsec)/';
$nics = array_values(array_filter(
    preg_split('/\s+/', trim((string)shell_exec('/sbin/ifconfig -l ether'))),
    fn($n) => $n !== '' && !preg_match($skip, $n)
));

$log = function (string $msg) {
    echo "openimages.cloud: $msg\n";
    syslog(LOG_NOTICE, "openimages.cloud: $msg");
};

if (count($nics) === 0) {
    $log('no network interface found, leaving the interface assignment to OPNsense');
    exit(0);
}

$ifs = &config_read_array('interfaces');
$changed = false;

if (!isset($ifs['wan']['if']) || !in_array($ifs['wan']['if'], $nics, true)) {
    $old = $ifs['wan']['if'] ?? 'none';
    $ifs['wan']['if'] = $nics[0];
    $log("WAN moved from $old to {$nics[0]}");
    $changed = true;
}

if (isset($ifs['lan']) && (!isset($ifs['lan']['if']) || !in_array($ifs['lan']['if'], $nics, true) || $ifs['lan']['if'] === $ifs['wan']['if'])) {
    $free = array_values(array_diff($nics, [$ifs['wan']['if']]));
    if (count($free) > 0) {
        $old = $ifs['lan']['if'] ?? 'none';
        $ifs['lan']['if'] = $free[0];
        $log("LAN moved from $old to {$free[0]}");
    } else {
        unset($ifs['lan']);
        if (isset($config['dnsmasq']['enable'])) {
            unset($config['dnsmasq']['enable']);
        }
        $log('single NIC: LAN removed, the instance is reached on its WAN');
    }
    $changed = true;
}

if ($changed) {
    write_config('openimages.cloud: interfaces matched to the NICs of this instance');
}
