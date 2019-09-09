---
layout: post
title: Kubernates 集群部署
date: 2016-10-01 05:03:17 +0800
description: 在虚拟机上部署 Kubernetes
tags: [Kubernetes]
---

#### kubernetes 结构图  
![kubernetes](../assets/img/kube-arch.png)  
（注：图片来自于 infoq.com）  
#### 软件环境：
1. centos 7 （Linux 3.10）  
2. docker 1.12.1  
3. kubernetes  1.3.7  
4. flannel 0.5.3  
5. etcd 2.3.7  

#### 硬件环境：
1. master 一台 centos7 服务器 (10.0.0.50)
2. minion 两台 centos7 服务器 (10.0.0.51，10.0.0.52)

#### 安装说明：
docker 负责容器管理  
kubernetes 负责集群管理  
flannel 负责承载集群网络，实现所有 minion 上的所有 container 之间的网络互通  
etcd 负责存储 kubernetes 和 flannel 的数据  

为了避免 ip 设置，使用以下域名：  
etcd.local 指向 etcd 数据库  
master.local 指向 kubernetes 的 master 服务器  
dns.local 指向 kubedns 的服务器  
hub.local 指向 docker 私有源的服务器  

#### 1. 在 master 和 minion 上安装 Docker  
在 yum 中添加 Docker 源：/etc/yum.repos.d/docker.repo
```bash
[dockerrepo]
name=Docker Repository
baseurl=https://yum.dockerproject.org/repo/main/centos/7/
enabled=1
gpgcheck=1
gpgkey=https://yum.dockerproject.org/gpg
```
安装 Docker：
```bash
yum install docker-engine
```

#### 2. 在 master 上安装 etcd && 在 minion 上安装 flannel  
```bash
# 只需要在 master 上安装
yum install etcd
# 只需要在 minion 上安装
yum install flannel
```

#### 3. 安装 kubernetes  
下载 kubernetes.tar.gz ：[https://github.com/kubernetes/kubernetes/releases](https://github.com/kubernetes/kubernetes/releases)    
kubernetes.tar.gz 中包含了已经编译过的二进制文件，找到其中适用于 linux 的 hypercube 和 kube-dns  
将 hypercube 复制到所有服务器的 / usr/local/bin 中  
将 kube-dns 复制到 master 的 / usr/local/bin    


#### 4. 在 master 上安装 Docker 私有源
下载 docker 私有源镜像：[https://hub.docker.com/\_/registry/](https://hub.docker.com/\_/registry/)  
下载 pause 镜像：[https://hub.docker.com/r/google/pause/](https://hub.docker.com/r/google/pause/)
```bash
docker pull registry
docker pull google/pause
```
由于 Docker pull 镜像需要使用 https，因此先创建证书：
```bash
mkdir certs
cd certs
openssl genrsa -out private.pem 2048
openssl req -new -x509 -key private.pem -out cert.pem -days 36500
cd ..
```
启动私有源镜像：
```bash
docker run -d -p 443:5000 --restart=always \
-v $(pwd)/repo:/var/lib/registry \
-v $(pwd)/auth:/auth \
-v $(pwd)/certs:/certs \
-e REGISTRY_HTTP_SECRET=1234567890 \
-e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/cert.pem \
-e REGISTRY_HTTP_TLS_KEY=/certs/private.pem \
registry
```
其中使用私有源默认监听 5000 端口，为了方便使用域名直接访问，在此处映射到 host 的 443 端口上。  
将 google/pause 镜像上传到私有源中：  
```bash
docker tag google/pause hub.local/pause
#push 失败则按第 5 步中说明先添加证书到信任列表
docker push hub.local/pause
```
google/pause 是 kubernetes 需要的基本镜像，kubernetes 在启动一个 pod 时，会先运行 pause 镜像，然后将 pod 定义的其他容器挂到 pause 上，以使用相同的 ip。 


#### 5. 配置 master 和 minion 服务器
将 cert.pem 导入到 master 和 minion 服务器的证书信任列表中：    
```bash
cat cert.pem >> /etc/pki/tls/certs/ca-bundle.crt
```
修改 master 和 minion 服务器的 / etc/hosts 文件，导入域名并指向 master 的 ip：
```bash
echo 10.0.0.50 etcd.local >> /etc/hosts
echo 10.0.0.50 master.local >> /etc/hosts
echo 10.0.0.50 dns.local >> /etc/hosts
echo 10.0.0.50 hub.local >> /etc/hosts
```

#### 6. 在 master 上启动 etcd
```bash
service etcd start
```
添加 flannel 要使用的子网的 key
```bash
etcdctl mk /flannel/network/config '{"Network":"10.254.0.0/16"}'
```

#### 7. 在 minion 上启动 flannel 和 dockerd
在所有的 minion 上执行：
```bash
flanneld -etcd-endpoints=http://etcd.local:2379 -etcd-prefix=/flannel/network
```
此时启动了 flanneld，flanneld 会从 http://etcd.local:2379 指向的 etcd 数据库中找到 / flannel/network 的 key，然后根据 Network 指定的子网分配当前 host 可用的子网，并将分配到的子网信息存储在 host 的 / run/flannel/docker 文件中。  
子网分配成功后，即可启动 dockerd
```bash
# 使用 / run/flannel/docker 中定义的全局变量来启动
source /run/flannel/docker
dockerd ${DOCKER_NETWORK_OPTIONS}
```


#### 8. 启动 master 上的 kubernetes 服务
```bash
# 启动 api 服务
hyperkube apiserver --etcd-servers=http://etcd.local:2379 \
 --logtostderr=true \
 --v=0 \
 --allow-privileged=false \
 --insecure-bind-address=0.0.0.0 \
 --insecure-port=8080 \
 --service-cluster-ip-range=10.254.0.0/16 \
 --logtostderr=false \
 --log-dir=/root/logs/apiserver/&

# 启动控制器管理器
hyperkube controller-manager --master=http://master.local:8080 \
 --logtostderr=false \
 --log-dir=/root/logs/controllermanager/&

# 启动调度器
hyperkube scheduler --master=http://master.local:8080 \
 --logtostderr=false \
 --log-dir=/root/logs/scheduler/&

# 启动 dns，minion 设置该 dns 后在 pod 中就可以使用服务域名来访问相应的服务
kube-dns --domain=kube.local --kube-master-url=http://master.local:8080 \
 --logtostderr=false \
 --log-dir=/root/logs/dns/ &

```

#### 9. 启动 minion 上的 kubernetes 服务
```bash
# 启动 kubelet
hyperkube kubelet --address=0.0.0.0 \
 --port=10250 \
 --hostname-override=10.0.0.51 \
 --api-servers=http://master.local:8080 \
 --cluster-dns=dns.local \
 --cluster-domain=kube.local \
 --pod-infra-container-image=hub.local/pause \
 --logtostderr=false \
 --log-dir=/root/logs/kubelet/ &


# 启动 proxy
hyperkube proxy --master=http://master.local:8080 \
 --logtostderr=false \
 --log-dir=/root/logs/proxy/ &
```
