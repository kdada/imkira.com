---
layout: post
title: Centos7 搭建 L2TP+ IPsec VPN
date: 2016-12-03 03:44:35 +0800
description: 在 Centos7 中搭建 L2TP+ IPsec VPN
tags: [Linux]
---

#### 软件说明：
* ppp：提供用户名密码验证功能，实现 VPN 的用户账号密码验证
* libreswan：提供 IPsec 功能，加密 IP 数据包
* xl2tpd：提供 VPN 功能，依赖于 ppp 和 libreswan

#### 系统环境：
* Centos 7
* Linux 3.10.0-327.36.3.el7.x86\_64
* ppp 2.4.5（系统自带，不需要额外安装）
* libreswan 3.15（需要安装）
* xl2tpd 1.3.6（需要安装）

```
yum install -y libreswan xl2tpd
```

#### VPN 配置
##### 1. 配置 IPsec（libreswan）
虽然可以直接在 */etc/ipsec.conf* 中进行配置，但是最好 */etc/ipsec.d/* 创建一个新的配置文件，只要扩展名为 *.conf* 即可。
```
# 创建一个新的配置文件
vi /etc/ipsec.d/vpn.conf
```
配置内容如下：
```
conn L2TP-PSK-NAT
    rightsubnet=vhost:%priv
    also=L2TP-PSK-noNAT

conn L2TP-PSK-noNAT
    authby=secret
    pfs=no
    auto=add
    keyingtries=3
    rekey=no
    ikelifetime=8h
    keylife=1h
    type=transport
    left = 这里填写服务器的外网 IP
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
```
在 */etc/ipsec.d/* 中有个默认的配置文件，不过是 IPv6 的，可以删除或者改个名字让其无效（这一步可做可不做）：
```
mv v6neighbor-hole.conf v6neighbor-hole.conf_bak
```
接下来设置 IPsec 的 Shared Key，这个 key 是 IPsec 的密钥，VPN 两端都会使用这个 key 来对 IP 数据包加密，防止数据包内容泄漏。  
同样的，可以在 */etc/ipsec.secrets* 文件中直接设置密钥，但是最好在 */etc/ipsec.d/* 创建一个新的密钥文件，只要扩展名是 *.secrets* 即可。  
```
vi /etc/ipsec.d/vpn.secrets
```
密钥设置格式如下（以 #开头的部分不需要写进文件里）：
```
# 例如：
# 11.22.33.44 %any: PSK "1234"
这里填写服务器的外网 IP %any: PSK "这里填写一个字符串作为密钥"
```
PSK 是 Password Shared Key，即使用密码作为密钥。也可以使用其他类型的 Shared Key，参考 *libreswan* 官方文档。

接下来可以启动 IPsec，并且设置为开机自动启动：
```
# 开机启动
systemctl enable ipsec
# 启动服务
systemctl start ipsec
```
启动 IPsec 后，还需要对 IPsec 进行验证，以确保 IPsec 能够正常工作：
```
ipsec verify

# 输出如下：
Verifying installed system and configuration files

Version check and ipsec on-path                   	[OK]
Libreswan 3.15 (netkey) on 3.10.0-327.36.3.el7.x86_64
Checking for IPsec support in kernel              	[OK]
 NETKEY: Testing XFRM related proc values
         ICMP default/send_redirects              	[NOT DISABLED]

  Disable /proc/sys/net/ipv4/conf/*/send_redirects or NETKEY will act on or cause sending of bogus ICMP redirects!

         ICMP default/accept_redirects            	[NOT DISABLED]

  Disable /proc/sys/net/ipv4/conf/*/accept_redirects or NETKEY will act on or cause sending of bogus ICMP redirects!

         XFRM larval drop                         	[OK]
Pluto ipsec.conf syntax                           	[OK]
Hardware random device                            	[N/A]
Two or more interfaces found, checking IP forwarding	[OK]
Checking rp_filter                                	[OK]
Checking that pluto is running                    	[OK]
 Pluto listening for IKE on udp 500               	[OK]
 Pluto listening for IKE/NAT-T on udp 4500        	[OK]
 Pluto ipsec.secret syntax                        	[OK]
Checking 'ip' command                             	[OK]
Checking 'iptables' command                       	[OK]
Checking 'prelink' command does not interfere with FIPSChecking for obsolete ipsec.conf options          	[OK]
Opportunistic Encryption                          	[DISABLED]

ipsec verify: encountered 2 errors - see 'man ipsec_verify' for help

```
验证结果中会出现 *OK*，*DISABLED*，*NOT DISABLED*。但是这里看不出这些字母颜色的区别，在 shell 中，分为绿色和红色两种颜色。绿色表示这一项检查通过，红色表示不通过需要修改。在上面的输出中，两个 *NOT DISABLED* 的项是红色的，需要处理。  

根据提示，需要关闭 send\_redirects 和 accept\_redirects：
```
# 查看这两个下的所有选项
# 根据网卡数量，选项个数无法确定
# 其中也可能会包含 IPv6 的选项，IPv6 的不需要改
sysctl -a |grep -e 'send_redirects'
sysctl -a |grep -e 'accept_redirects'
```
可以直接通过下面的脚本把上面显示的所有 IPv4 的选项全部设置为 0 ：
```
#!/bin/bash
for each in /proc/sys/net/ipv4/conf/*
do
    echo 0 > $each/send_redirects
    echo 0 > $each/accept_redirects
done
```
修改完成后，再进行一次 *ipsec* 验证即可看到结果，所有的输出项都会变成绿色。如果仍然有红色的部分，根据提示设置即可。

开启 IPv4 的 ip\_forward，这个选项用于做 IP 包的转发：
```
sysctl net.ipv4.ip_forward=1
```

##### 2. 配置 xl2tpd
```
vi /etc/xl2tpd/xl2tpd.conf
```
主要修改配置文件中的 ip range 和 local ip：
```
# 注意这个 ip range 不要与本地 ip 和服务器的其他 ip 冲突
# 这是一个例子：
ip range = 192.168.79.100-192.168.79.200
local ip = 192.168.79.1
```
在 */etc/xl2tpd/xl2tpd.conf* 中的能看到：
```
pppoptfile = /etc/ppp/options.xl2tpd
```
表示引用了 ppp 的配置文件，可以通过这个配置文件修改 ppp 的设置：
```
vi /etc/ppp/options.xl2tpd
```
```
# 修改 ms-dns，可以修改为其他合适的 dns 地址
ms-dns 114.114.114.114

# 增加 require-mschap-v2 选项，否则 windows 无法连接
require-mschap-v2

```

设置 ppp 的账号密码：
```
# 按文件中说明填写用户名密码即可
# 例如
# 用户名	*	密码 	*
vi /etc/ppp/chap-secrets
```
这里第二列是服务名，\* 的意思是任何服务都可以使用，默认使用这个即可。

接下来可以启动 xl2tpd，并且设置为开机自动启动：
```
# 开机启动
systemctl enable xl2tpd
# 启动服务
systemctl start xl2tpd
```

如果需要查看 xl2tpd 的日志，可以不使用上面的启动方法，直接使用：
```
xl2tpd -D
```

#### 配置防火墙
使用 iptables 作为范例：
* 需要打开 500，4500，1701 三个端口的 udp 通信
```
iptables -t filter -A INPUT -p udp -m multiport --dports 500,4500,1701 -j ACCEPT
```
* 打开转发时的地址伪装
```
iptables -t nat -A POSTROUTING -j MASQUERADE
```
* 允许已经建立的链接的包进入服务器
```
iptables -t filter -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
```
