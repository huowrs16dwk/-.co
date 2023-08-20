#!/bin/env bash

echo "---
title: Post
date: $(date +'%Y-%m-%d')
---

# {{ title }}

" > posts/$(date +'%Y-%m-%d').md 
