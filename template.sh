#!/bin/env bash

echo "---
title: Post
date: $(date +'%Y-%m-%d')
---
" > posts/$(date +'%Y-%m-%d').md 
