---
layout: post
title: connecting to github securely
date: 2023-07-30
---

# {{ title }}

First make sure you have tor running.  Either start the daemon process or run it manually with `tor`

```
	sudo systemctl start tor
```

```
$ cat ~/.ssh/config
Host github.com
    User git
    IdentitiesOnly yes
    ProxyCommand nc -X 5 -x 127.0.0.1:9050 %h %p
```
