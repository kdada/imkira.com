---
layout: post
title: 使用 Docker 搭建 Keepalived 高可用集群
date: 2016-12-26 09:25:05 +0800
description: 使用 Docker 搭建 Keepalived 高可用集群
tags: [Docker, Keepalived]
---

#### KeepAlived 镜像构建
Dockerfile 文件如下：
```Dockerfile
FROM debian:jessie

RUN apt-get update &&\
    apt-get install -y keepalived

ADD ./entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT /entrypoint.sh

CMD keepalived -l -n -D

```

entrypoint.sh 启动脚本:
```bash
#!/bin/bash
set -e

exec "$@"
```
启动脚本只是简单地将参数作为命令执行，如果有需要，可以在该脚本中做一些检查或者其它必要处理。  
特别注意：启动脚本必须使用 exec 命令启动 keepalived ，否则会导致在使用 docker stop 等命令停止容器时，Keepalived 无法正确关闭。  

原因：  
1. docker stop 在停止容器时，会先向容器发送 SIGTERM 信号，然后等待容器中进程 ID 为 1 的进程主动退出。如果容器 10 秒（默认值，可修改）内没有退出，
 docker 会发送 SIGKILL 强制关闭进程。  
2. 使用 exec 启动的命令将会继承当前的 shell 脚本的 PID ，但是进程会被替换为 exec 执行的那个命令的进程。 也就是说，进程 ID 不变，但是进程已经是新的进程了。  
3. shell 进程不会主动处理 SIGTERM 信号，导致 shell 进程会被强制关闭，同时 keepalived 进程也会因此被强制关闭。使用 exec 后 shell 进程被 keepalived 
 进程替换，而 keepalived 进程能够处理信号，因此能够正常的关闭退出。

 不正常关闭可能会出现以下问题（重启可解决）：
 * 容器再启动时会一直处于重启中状态
 * 无法启动一个新的 keepalived


将启动脚本和 Dockerfile 放置在同一目录之后即可使用 docker 命令构建：
```
docker build -t keepalived .
```

#### KeepAlived 配置
配置如下：
```bash
vrrp_script check {
    script "python /etc/keepalived/check.py" 
    interval 5
    weight -3
    fall 2  
    rise 1
}

vrrp_instance server {
    state BACKUP
    interface eth0
    virtual_router_id 72
    priority 100
    nopreempt
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass Hf9saFkj
    }
    virtual_ipaddress {
        10.0.0.33
    }
    track_script {
        check
    }
}
```
vrrp\_script 节定义了一个脚本，字段含义如下：
* script：脚本命令，通常可以用来执行一个脚本
* interval：调用间隔时间，以秒为单位
* weight：权重，脚本返回非 0 值时，priority += weight
* fall: 当脚本连续返回 fall 次非 0 值时，就认为当前节点处于失败状态
* rise：当脚本连续返回 rise 次 0 值时，就认为当前节点处于正常状态

vrrp\_instance 定义了一个节点，字段含义如下：
* state：初始状态，即 Keepalived 刚启动时的状态。如果想要搭建单主的集群，
 那么最好所有节点都设置为 BACKUP ，这样 Keepalived 会自动选举出 master 节点
* interface：网卡接口名称
* virtual\_router\_id：标志当前节点的路由 id ，同一个路由 id 的节点为一个组
* priority：优先级 1 - 255 。在同一时间，最高优先级的节点能够抢占并成为 master 节点，其它低优先级的节点需要让出 master
* nopreempt：如果设置了该选项，则表示即使存在低优先级的节点处于 master 状态，也不会去抢占
* advert\_int：广播间隔，以秒为单位。即每隔 advert\_int 秒发送一次通知广播，告诉其他节点当前节点的状态
* authentication：鉴权选项，用于同组之间的节点校验身份。此处使用密码鉴权，auth\_pass 最长 8 位
* virtual\_ipaddress：Virtual IP 组，可以设置多个 VIP ， master 节点拥有 VIP 的使用权
* track\_script：健康检查脚本，在这个字段中定义的脚本会用来调整当前节点的 priority

#### KeepAlived 启动
使用如下命令启动：
```
docker run -d --restart always --privileged --network=host -v /path/to/keepalived/config:/etc/keepalived keepalived
```
需要使用 privileged 启动并且必须是 host 网络。
