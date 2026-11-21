<?php
/*
 * openimages.cloud first-boot layer for OPNsense (start syshook, every boot,
 * acts once per instance).
 *
 * Metadata sources, first found wins:
 *   1. config drive (label config-2): OpenStack, Proxmox "configdrive2";
 *   2. NoCloud drive (label cidata): Proxmox cloud-init drive;
 *   3. OpenStack metadata service (169.254.169.254).
 *
 * Applied once per instance id:
 *   - SSH keys of root (public_keys, cloud-config ssh_authorized_keys);
 *   - hostname (cloud-config hostname, else the instance hostname);
 *   - web GUI / console password of root, in this order:
 *       a. cloud-config `password:` (plain, or a crypt hash as Proxmox writes
 *          it); never printed anywhere;
 *       b. otherwise, on the first instance only, a generated 24-character
 *          password, always written to the serial console and, when the
 *          metadata service is reachable and the key is RSA, stored
 *          encrypted for `nova get-password`;
 *       c. always available: SSH as root with the key, then
 *          `opnsense-shell password` (console menu option 3).
 * Never logs a password: /var/log/oic-firstboot.log only records the steps.
 */

require_once 'config.inc';
require_once 'auth.inc';
require_once 'util.inc';
require_once 'interfaces.inc';
require_once 'system.inc';

const OIC_LOG = '/var/log/oic-firstboot.log';
const OIC_DONE = '/conf/oic-instance-id';
const OIC_UNSET = '/conf/oic-password-unset';
const OIC_MD = 'http://169.254.169.254';

function logm(string $msg): void
{
    @file_put_contents(OIC_LOG, gmdate('Y-m-d\TH:i:s\Z') . " $msg\n", FILE_APPEND);
    echo "openimages.cloud: $msg\n";
}

function console(string $text): void
{
    /* /dev/console reaches the serial console (OpenStack console log) and the VGA one */
    @file_put_contents('/dev/console', $text);
}

function run(string $cmd, ?string &$out = null): bool
{
    $lines = [];
    exec($cmd . ' 2>/dev/null', $lines, $rc);
    $out = implode("\n", $lines);
    return $rc === 0;
}

/* GET on the metadata service: body, '' on 404, null when unreachable */
function md_get(string $path, int $tries): ?string
{
    for ($i = 0; $i < $tries; $i++) {
        $tmp = tempnam('/tmp', 'oic');
        $code = '';
        run(sprintf('/usr/local/bin/curl -sS -m 5 -o %s -w "%%{http_code}" %s', escapeshellarg($tmp), escapeshellarg(OIC_MD . $path)), $code);
        $body = (string)@file_get_contents($tmp);
        @unlink($tmp);
        if ($code === '200') {
            return $body;
        }
        if ($code === '404') {
            return '';
        }
        if ($i + 1 < $tries) {
            sleep(5);
        }
    }
    return null;
}

function read_drive(string $label, array $files): ?array
{
    foreach (['iso9660' => 'cd9660', 'msdosfs' => 'msdosfs'] as $dir => $fs) {
        foreach ([$label, strtoupper($label)] as $name) {
            $dev = "/dev/$dir/$name";
            if (!file_exists($dev)) {
                continue;
            }
            $mnt = '/tmp/oic-drive';
            @mkdir($mnt, 0700);
            if (!run(sprintf('/sbin/mount -t %s -o ro %s %s', $fs, escapeshellarg($dev), $mnt))) {
                continue;
            }
            $got = [];
            foreach ($files as $key => $file) {
                $got[$key] = is_file("$mnt/$file") ? (string)file_get_contents("$mnt/$file") : '';
            }
            run("/sbin/umount $mnt");
            @rmdir($mnt);
            return $got;
        }
    }
    return null;
}

function unquote(string $v): string
{
    $v = trim($v);
    if (strlen($v) >= 2 && ($v[0] === '"' || $v[0] === "'") && substr($v, -1) === $v[0]) {
        $v = substr($v, 1, -1);
    }
    return $v;
}

/* the few cloud-config keys this layer honours */
function parse_cloud_config(string $ud): array
{
    $r = ['password' => null, 'hostname' => null, 'fqdn' => null, 'keys' => []];
    if (!preg_match('/^#cloud-config\b/', ltrim($ud))) {
        return $r;
    }
    $in_keys = false;
    foreach (preg_split('/\r?\n/', $ud) as $line) {
        if (preg_match('/^(password|hostname|fqdn):\s*(.*)$/', $line, $m)) {
            $r[$m[1]] = unquote($m[2]);
            $in_keys = false;
        } elseif (preg_match('/^ssh_authorized_keys:\s*$/', $line)) {
            $in_keys = true;
        } elseif ($in_keys && preg_match('/^\s+-\s*(.+)$/', $line, $m)) {
            $r['keys'][] = unquote($m[1]);
        } elseif ($in_keys && preg_match('/^\S/', $line)) {
            $in_keys = false;
        }
    }
    return $r;
}

function nocloud_value(string $yaml, string $key): ?string
{
    return preg_match('/^' . preg_quote($key, '/') . ':\s*(.+)$/m', $yaml, $m) ? unquote($m[1]) : null;
}

function random_password(int $len): string
{
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    $p = '';
    for ($i = 0; $i < $len; $i++) {
        $p .= $alphabet[random_int(0, strlen($alphabet) - 1)];
    }
    return $p;
}

/* encrypt for `nova get-password` (RSA PKCS#1 v1.5, base64) and store it */
function nova_store_password(string $password, array $keys): string
{
    $rsa = null;
    foreach ($keys as $k) {
        if (str_starts_with($k, 'ssh-rsa ')) {
            $rsa = $k;
            break;
        }
    }
    if ($rsa === null) {
        return 'skipped (no RSA key: nova get-password needs one)';
    }
    $dir = sys_get_temp_dir() . '/oic-pw-' . bin2hex(random_bytes(4));
    mkdir($dir, 0700);
    file_put_contents("$dir/key.pub", $rsa . "\n");
    file_put_contents("$dir/pw", $password);
    $ok = run("/usr/bin/ssh-keygen -e -m PKCS8 -f $dir/key.pub > $dir/key.pem")
        && run("/usr/local/bin/openssl pkeyutl -encrypt -pubin -inkey $dir/key.pem -in $dir/pw | /usr/local/bin/openssl base64 -A > $dir/pw.enc");
    $code = '';
    if ($ok) {
        run(sprintf('/usr/local/bin/curl -sS -m 10 -o /dev/null -w "%%{http_code}" -X POST --data-binary @%s %s',
            "$dir/pw.enc", escapeshellarg(OIC_MD . '/openstack/latest/password')), $code);
    }
    run('/bin/rm -rf ' . escapeshellarg($dir));
    if (!$ok) {
        return 'failed (could not encrypt with the RSA key)';
    }
    return $code === '200' ? 'stored for nova get-password' : "not stored (metadata service answered $code)";
}

/* ---------------------------------------------------------------------- */

$done = is_file(OIC_DONE) ? trim((string)file_get_contents(OIC_DONE)) : '';
$source = null;
$meta = [];
$ud = '';
$md_reachable = false;

if (($d = read_drive('config-2', ['meta' => 'openstack/latest/meta_data.json', 'ud' => 'openstack/latest/user_data'])) !== null) {
    $source = 'config drive';
    $meta = json_decode($d['meta'], true) ?: [];
    $ud = $d['ud'];
} elseif (($d = read_drive('cidata', ['meta' => 'meta-data', 'ud' => 'user-data'])) !== null) {
    $source = 'NoCloud drive';
    $meta = [
        'uuid' => nocloud_value($d['meta'], 'instance-id'),
        'hostname' => nocloud_value($d['meta'], 'local-hostname'),
    ];
    $ud = $d['ud'];
}
/* the metadata service: source when there is no drive, and the place for the password */
$md_meta = md_get('/openstack/latest/meta_data.json', $source === null && $done === '' ? 24 : 2);
if ($md_meta !== null && $md_meta !== '') {
    $md_reachable = true;
    if ($source === null) {
        $source = 'metadata service';
        $meta = json_decode($md_meta, true) ?: [];
        $ud = (string)md_get('/openstack/latest/user_data', 3);
    }
}

$instance = (string)($meta['uuid'] ?? '') ?: 'none';
if ($instance === $done) {
    exit(0);
}
logm('instance ' . $instance . ', metadata from ' . ($source ?? 'nowhere (no drive, no metadata service)'));

$cc = parse_cloud_config($ud);
$keys = array_values(array_unique(array_filter(array_map('trim', array_merge(
    array_values((array)($meta['public_keys'] ?? [])),
    $cc['keys']
)))));
$hostname = $cc['hostname'] ?: ($meta['hostname'] ?? null) ?: ($meta['name'] ?? null);

$root = &getUserEntryByUID(0);
if (!$root) {
    logm('root user missing from config.xml: nothing applied');
    exit(1);
}

if (count($keys) > 0) {
    $root['authorizedkeys'] = base64_encode(implode("\n", $keys));
    logm(count($keys) . ' SSH key(s) installed for root');
} else {
    logm('no SSH key in the metadata: root keys unchanged');
}

$generated = null;
if ($cc['password'] !== null && $cc['password'] !== '') {
    if ($cc['password'][0] === '$') {
        $root['password'] = $cc['password'];
    } else {
        local_user_set_password($root, $cc['password']);
    }
    @unlink(OIC_UNSET);
    logm('root password set from the user data');
} elseif (is_file(OIC_UNSET)) {
    $generated = random_password(24);
    local_user_set_password($root, $generated);
    logm('root password generated');
} else {
    logm('root password unchanged (set on an earlier instance)');
}
local_user_set($root);

if ($hostname) {
    $parts = explode('.', strtolower($hostname), 2);
    $short = substr(trim(preg_replace('/[^a-z0-9-]+/', '-', $parts[0]), '-'), 0, 63);
    if ($short !== '') {
        $config['system']['hostname'] = $short;
        if (!empty($parts[1]) && preg_match('/^[a-z0-9.-]+$/', $parts[1])) {
            $config['system']['domain'] = $parts[1];
        }
        logm("hostname $short");
    }
}

if (write_config('openimages.cloud: instance metadata applied') === false) {
    logm('config.xml could not be written');
    exit(1);
}
@unlink(OIC_UNSET);
system_hostname_configure();
system_resolver_configure();

if ($generated !== null) {
    $nova = $md_reachable ? nova_store_password($generated, $keys) : 'skipped (no metadata service)';
    logm("generated password: console, $nova");
    $bar = str_repeat('=', 64);
    console("\n$bar\nopenimages.cloud: OPNsense web GUI and console login\n" .
        "  user:     root\n  password: $generated\n" .
        "Change it after the first login (System: Access: Users).\n$bar\n\n");
}

file_put_contents(OIC_DONE, $instance . "\n");
logm('status: done');
