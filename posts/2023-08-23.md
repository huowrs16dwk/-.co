---
layout: post
title: home lab hybrid cloud setup
date: 2023-08-23
---

# {{ title }}

In this hybrid setup I'm using the cloud server as a proxy for various subdomains to make them public with certificates but keeping the backend services running in the home lab.  It's cheaper and easier to run something locally on my network but I can't serve 80 or 443 from it. Moreover, if my ip address changes it would mean I would also need to make dns updates or do something with dyndns. No need for that here because if the home lab ip changes it doesn't effect the wireguard tunnel addresses. The general concept is that from a single cheap g6-nanode-1 instance you can serve a lot of functionality with all the main components of your architecture hosted inside the homb lab like the db, elasticsearch, api services, cron jobs, etc. assuming your power and internet are stable at home of course.


There are three key components to this.

- The cloud service (I'm going to use linode in this example)
- The wireguard tunnel (You can use tailscale but I'll do a manual setup here)
- The home lab setup (In my case, an intel nuc)


## setting up the tunnel

We will start with setting up the tunnel, but we need a server first

```
	linode linodes create --root_pass=$(bw generate)
```

first things first, ssh into the cloud server, then poke some holes in the firewall for cloud traffic

```
	ufw allow 22/tcp 	# ssh
	ufw allow 51820/udp     # wireguard
	ufw allow 80/tcp	# letsencrypt http01 validation
	ufw allow 443/tcp       # secured api
	ufw enable
```

next, on the cloud server and the home lab server, we need to create some keys. 

```
	apt-get install -y wireguard wireguard-tools
	cd /etc/wireguard
	wg genkey | tee privatekey | wg pubkey > publickey
```

Now that we have our keys we can set our peer configuration. We are going to use the 10.8.0.0/24 block for our network, edit /etc/wireguard/wg0.conf on the cloud server:

```
	[Interface]
	Address = 10.8.0.1/24
	ListenPort = 51820
	PrivateKey = <cloud_server_private_key>

	[Peer]
	PublicKey = <home_lab_public_key>
	AllowedIPs = 10.8.0.2/32
	PersistentKeepalive = 25
```


Next edit /etc/wireguard/wg0.conf on the home lab server and add entries. The keep-alive is important, otherwise your tunnel will go down after inactivity

```
	[Interface]
	PrivateKey = <home_lab_private_key>
	Address = 10.8.0.2/24

	[Peer]
	PublicKey = <cloud_server_public_key>
	AllowedIPs = 10.8.0.0/24
	Endpoint = <cloud_server_public_ip>:51820
	PersistentKeepalive = 25
```

And now on both the home lab and the cloud server, enable the service

```
	systemctl enable --now wg-quick@wg0
```

You can debug by showing the wireguard configuration

```
	wg show
```


Now we can test, from the home lab server we should be able to ping .1 and from the cloud server we should be able to ping .2

```
	homelab$ ping 10.8.0.1
	cloud$ ping 10.8.0.2
```

## Setting up k3s and certificate manager on the cloud server

I'm using k3s a lightweight alternative to kube that comes with traefik for routing

```
	curl -sfL https://get.k3s.io | sh -
```

Now, install certificate manager

```
	kubectl create namespace cert-manager
	kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml
```

You can follow the same steps with the home lab server to install k3s. You can make this as complicated as you want, to keep it simple and to ease resource usage on the nanode I'm avoiding things like argocd.

## Deploying the api

For demonstration purposes, let's deploy an elasticsearch api. In reality this would probably be left as a backend service and a custom api would be exposed instead. Apply the deployment yaml to the home lab:

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: elasticsearch-deployment
  labels:
    app: elasticsearch
spec:
  replicas: 1
  selector:
    matchLabels:
      app: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
    spec:
      containers:
      - name: elasticsearch
        image: elasticsearch:8.8.1
        ports:
        - containerPort: 9200
        env:
        - name: discovery.type
          value: single-node
        - name: xpack.security.enabled
          value: "false"
---
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch-service
spec:
  type: NodePort
  selector:
    app: elasticsearch
  ports:
  - protocol: TCP
    port: 9200
    targetPort: 9200
    nodePort: 31200

```

This starts the elasticsearch api and it to the node port 31200.  Note also that security is turned off.  The wireguard tunnel is encrypted and the http traffic is encrypted and if we had security on we would have certificate handling issues trying to intercept and forward the traffic.

```
	kubectl create namespace api
	kubectl -n api apply -f deployment.yaml
```


And we should be able to get to it from our cloud server:

```
	curl 'http://10.8.0.2:31200/_cluster/health?pretty'

	{
	  "cluster_name" : "docker-cluster",
	  "status" : "green",
	  "timed_out" : false,
	  "number_of_nodes" : 1,
	  "number_of_data_nodes" : 1,
	  "active_primary_shards" : 0,
	  "active_shards" : 0,
	  "relocating_shards" : 0,
	  "initializing_shards" : 0,
	  "unassigned_shards" : 0,
	  "delayed_unassigned_shards" : 0,
	  "number_of_pending_tasks" : 0,
	  "number_of_in_flight_fetch" : 0,
	  "task_max_waiting_in_queue_millis" : 0,
	  "active_shards_percent_as_number" : 100.0
	}
```

## Setting up the cloud proxy

First, we need a dns record, go to your domain's dns management and add a record for the new api

```
	api	3600	 IN 	A	70.165.208.213
```

Now we can proxy to it from our cloud server.  The trick is setting the endpoint for the service manually.

cluster-issuer.yaml:

```
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: huowrs16dwk@proton.me
    privateKeySecretRef:
      name: letsencrypt
    solvers:
    - http01:
        ingress:
          class: traefik
```

ronin-api-proxy.yaml:

```
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: ronin-api
  namespace: default
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(`api.xn--gmqy16e.co`)
      kind: Rule
      services:
        - name: ronin-api-proxy
          port: 80
  tls:
    secretName: api.xn--gmqy16e.co
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api.xn--gmqy16e.co
  namespace: default
spec:
  dnsNames:
    - api.xn--gmqy16e.co
  secretName: api.xn--gmqy16e.co
  issuerRef:
    name: letsencrypt
    kind: Issuer
---
apiVersion: v1
kind: Service
metadata:
  name: ronin-api-proxy
  namespace: default
spec:
  ports:
  - protocol: TCP
    port: 80
    targetPort: 31200
---
apiVersion: v1
kind: Endpoints
metadata:
  name: ronin-api-proxy
  namespace: default
subsets:
- addresses:
    - ip: 10.8.0.2
  ports:
    - port: 31200
```

## Debugging certificates

You can watch the certificate manager progress by checking a few cert manager objects

```
	kubectl describe certificate api.xn--gmqy16e.co
	kubectl describe certificaterequest api.xn--gmqy16e.co-nwzxm
	kubectl describe order api.xn--gmqy16e.co-nwzxm-1892479097
```

Testing the public route

```
	curl https://api.xn--gmqy16e.co
	{
	  "name" : "elasticsearch-deployment-7488648ff6-7bqsl",
	  "cluster_name" : "docker-cluster",
	  "cluster_uuid" : "2KXZPPPSTjiKlA6rklwQRQ",
	  "version" : {
	    "number" : "8.8.1",
	    "build_flavor" : "default",
	    "build_type" : "docker",
	    "build_hash" : "f8edfccba429b6477927a7c1ce1bc6729521305e",
	    "build_date" : "2023-06-05T21:32:25.188464208Z",
	    "build_snapshot" : false,
	    "lucene_version" : "9.6.0",
	    "minimum_wire_compatibility_version" : "7.17.0",
	    "minimum_index_compatibility_version" : "7.0.0"
	  },
	  "tagline" : "You Know, for Search"
	}
```


Now we have a generic cloud proxy that we can use to capture 80 and 443 with real certificates on nearly any domain but keep the main components of the architecture on-site and save a lot of money in cloud hosting.
