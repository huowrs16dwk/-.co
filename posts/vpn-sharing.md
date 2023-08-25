---
layout: post
title: vpn sharing
date: 2023-08-20
---

# {{ title }}

First, connect the vpn.  In my case I'm using mozilla which creates a moz0 network interface.  If you are using openvpn it will probably create a tun0 interface.  Once you have your interface created and the vpn is connected, you can share the connection with other computers on the network by forcing it to act as a gateway.


The first step is to turn on ip forwarding in the kernel, you can do this by editing sysctl.conf


```
	echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
	echo "net.ipv6.conf.all.forwarding = 1" | sudo tee -a /etc/sysctl.conf

	sysctl -p
```

The next step is setting up nat forwarding for the interface.  In my case I'm sharing the vpn with other computers on the wifi interface wlp2s0b1


```
	# ipv4
	iptables -t nat -A POSTROUTING -o moz0 -j MASQUERADE
	iptables -A FORWARD -i moz0 -o wlp2s0b1 -m state --state RELATED,ESTABLISHED -j ACCEPT
	iptables -A FORWARD -i wlp2s0b1 -o moz0 -j ACCEPT

	# ipv6
	ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
	ip6tables -A FORWARD -i moz0 -o wlp2s0b1 -m state --state RELATED,ESTABLISHED -j ACCEPT
	ip6tables -A FORWARD -i wlp2s0b1 -o moz0 -j ACCEPT
```

Next, on another computer on the network, you need to set the default gateway to be the forwarded interface.

```
	# ipv4
	sudo ip -4 route delete default
	sudo ip -4 route add default via 192.168.1.1 # ip of the vpn gateway wlp interface

	# ipv6
	sudo ip -6 route delete default
	sudo ip -6 route add default via 2604:8180:d910:900::1b02 # ipv6 address of the wlp interface
```

Now you can test it with curl:

```
	# public ip will be the vpn value
	curl -4 ifconfig.me
	curl -6 ifconfig.me
```

To persist the changes on the gateway forever, you'll need to save the iptables rules:

```
	sudo apt-get install -y iptables-persistent ip6tables-persistent
	sudo netfilter-persistent save
```
