---
layout: post
title: hybrid cloud mail server
date: 2024-07-14
---

# {{ title }}

Running mailcow in the cloud can be expensive as it uses a lot of system resources, but running from a local server and using the cloud only for it's public ipv4 address can save some money and provide better security in that the mail physically lives at a known location. Physical access is root access.

It's possible to setup a local server and use something like [ipv6.rs](https://ipv6.rs/) to have a public ipv6 address.  Another option is something like [cloudflare tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) but that means you have to hand complete control of the domain over to cloudflare. If you just want a clean public ipv4 address you'll need a cloud server with minimum specs.  Find one with [host2go](https://search.host2go.net/). For proper mail delivery you'll also need to ensure your host allows [reverse dns](https://dnschecker.org/reverse-dns.php) for the IP to point back to the mail domain.

[Setup the wireguard tunnel](/posts/home-lab-hybrid-cloud-setup).
This assumes the cloud server is `10.8.0.1` and the local server is `10.8.0.2`.
By setting allowed ips to `0.0.0.0/0` it will use the server as the default gateway.
Outbound traffic will not work until after nat is enabled on the cloud server.

Example local server wg0.conf

```text
[Interface]
PrivateKey = <local_server_private_key>
Address = 10.8.0.2/24

[Peer]
PublicKey = <cloud_server_public_key>
AllowedIPs = 0.0.0.0/0
Endpoint = <cloud_server_public_ip>:51820
PersistentKeepalive = 25
```

Connect the wireguard tunnel on cloud and local servers.  The local server outbound traffic won't work until after the next step.

```bash
systemctl enable --now wg-quick@wg0
```

Enable forwarding on the cloud server, this allows nat/masquerading to work with iptables.

```bash
# cloud server

echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

Setup firewall rules to forward mail server ports.
At least http is needed for acme certificate requests, but https can be skipped.

```bash
# cloud server

apt install -y iptables iptables-persistent

# forward inbound mail server ports to wireguard peer

iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 465 -j DNAT --to-destination 10.8.0.2:465
iptables -t nat -A POSTROUTING -o wg0 -p tcp --dport 465 -d 10.8.0.2 -j MASQUERADE

iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 587 -j DNAT --to-destination 10.8.0.2:587
iptables -t nat -A POSTROUTING -o wg0 -p tcp --dport 587 -d 10.8.0.2 -j MASQUERADE

iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 993 -j DNAT --to-destination 10.8.0.2:993
iptables -t nat -A POSTROUTING -o wg0 -p tcp --dport 993 -d 10.8.0.2 -j MASQUERADE

# forward web ports for acme certificate renewal

iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 80 -j DNAT --to-destination 10.8.0.2:80
iptables -t nat -A POSTROUTING -o wg0 -p tcp --dport 80 -d 10.8.0.2 -j MASQUERADE

iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 443 -j DNAT --to-destination 10.8.0.2:443
iptables -t nat -A POSTROUTING -o wg0 -p tcp --dport 443 -d 10.8.0.2 -j MASQUERADE

# allow as default outbound gateway

iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# save firewall rules

netfilter-persistent save
```

At this point we effectively have our own custom vpn service, you should see your cloud ip for any outbound activity from the local server

```bash
# from local server

curl ifconfig.me
# should print cloud server ip
```

Next, setup mailcow on the local server. Boot it up then add your domains and configure dns as appropriate.

```bash
# local server

git clone https://github.com/mailcow/mailcow-dockerized
cd mailcow-dockerized
./generate_config.sh

docker compose up -d
```

The easydmarc [dmarc generator](https://easydmarc.com/tools/dmarc-record-generator) and [spf record generator](https://easydmarc.com/tools/spf-record-generator) tools are useful when setting up dns.

