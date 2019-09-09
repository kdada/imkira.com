---
layout: post
title: CentOS 7 Linux netfilter 日志
date: 2016-11-18 02:23:06 +0800
description: netfilter 日志启用方法
tags: [Linux]
---

查看 netfilter ipv4 日志状态
```
cat /proc/sys/net/netfilter/nf_log/2

# 输出:
nf_log_ipv4
```
如果输出是
```
NONE
```
那么说明没有配置日志，可以通过 sysctl 设置：
```
modprobe nf_log_ipv4
sysctl net.netfilter.nf_log.2=nf_log_ipv4
```

除了配置 netfilter 使用日志以外，还需要配置 rsyslog（配置路径：/etc/rsyslog.conf）  
默认情况下，kern 规则会被注释，导致不会输出内核日志
```
# Log all kernel messages to the console.
# Logging much else clutters up the screen.
# kern.*                                                  /dev/console
```
去除前面的 #，然后修改日志路径：
```
kern.*                                                  /var/log/kernlog
```

修改完成后，重启 rsyslog
```
service rsyslog restart
```
完成之后即通过 / var/log/kernlog 文件查看系统日志
