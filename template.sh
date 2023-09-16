#!/bin/env bash

echo "---
layout: post
title: Post
date: $(date +'%Y-%m-%d')
---

# {{ title }}

" > "posts/$1.md" 
