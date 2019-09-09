---
layout: post
title: 在 OSX 上安装最小化 Linux 开发环境
date: 2018-07-23 11:31:37 +0800
description: 在 OSX 上安装最小化 Linux 开发环境
tags: [Linux]
---
 

### 准备工具
Virtual Box 下载地址：https://www.virtualbox.org/wiki/Downloads
Fedora Server 下载地址：https://getfedora.org/zh\_CN/server/download/

在 OSX 下安装一个无桌面的 Linux 开发环境。主要完成三个目标：
1. 剪贴板共享
2. 文件共享
3. 使用 linux 的命令行和开发环境（使用 ssh 配合 zsh+tmux+vim）

### 虚拟机设置
Virtual Box 关键配置如下： 
1. 常规 - 高级 - 共享剪贴板：双向
2. 系统 - 主板 - 内存大小：足够大
3. 系统 - 主板 - 启动顺序：硬盘 > 光驱
4. 系统 - 处理器 - 处理器数量：最大
5. 存储 - 存储介质 - 光驱：Fedora ISO
6. 网络 - 网卡 1 - 网络地址转换(NAT)
7. 网络 - 网卡 2 - 仅主机 (Host-Only) 网络：选择一个接口
    * 这个需要先在全局工具 - 主机网路管理器里创建
    * 设置 IPv4 地址和掩码，不需要启用 DHCP 服务器
8. 共享文件夹：共享代码文件夹

备注：Virtual Box 可以使用 shift + 启动 启动虚拟机但不打开虚拟机 UI 界面

### 安装 Fedora Server 和 VBox 组件
安装 Fedora，过程中需要配置网卡，第一张网卡无需配置，主要是第二张网卡的 IP 地址和掩码需要设置一下。

安装完成后，重启，弹出光驱。然后在虚拟机界面的菜单中插入 VBox 的组件：Devices -> Insert Guest Additions CD Image…

更新系统：
```
dnf update kernel*
dnf install gcc kernel-devel kernel-headers dkms make bzip2 perl
dnf install xorg-x11-server-Xorg libXrandr
dnf install xclip
reboot

mkdir /media/cdrom
mount -r /dev/cdrom /media/cdrom
cd /media/cdrom
export KERN_DIR=/usr/src/kernels/`uname -r`/build
./VBoxLinuxAdditions.run
reboot
```

基础组件安装完成后，开机需要启动两个服务：
1. X :0：用于提供剪切板服务，指定显示编号为 :0
2. DISPLAY=:0：环境变量，用于给各种需要剪贴板的服务指定显示编号
3. VBoxClient --clipboard：用于同步主机和虚拟机的剪贴板

开机自启动服务：

/etc/systemd/system/x.service
```
[Unit]
Description=X Server
Requires=network.target

[Service]
Type=simple
ExecStart=/usr/bin/X :0

[Install]
WantedBy=multi-user.target
```

/etc/systemd/system/vboxclient.service 
```
[Unit]
Description=VBoxClient
After=x.service

[Service]
Type=forking
ExecStart=/usr/bin/bash /usr/bin/StartVBoxClient.sh

[Install]
WantedBy=multi-user.target
```

/usr/bin/StartVBoxClient.sh
```
#/bin/bash

set -e;

# waiting for x server running
sleep 3;

DISPLAY=:0 /usr/bin/VBoxClient --clipboard;
```

可以通过以下命令检查剪贴板同步是否正常（需要 DISPLAY 环境变量）：

写入剪贴板：
```
echo test | xclip -sel clipboard -i
```
读取剪贴板：
```
xclip -sel clipboard -o
```

挂载共享文件夹：
```
mount -t vboxsf dev /root/dev
```
