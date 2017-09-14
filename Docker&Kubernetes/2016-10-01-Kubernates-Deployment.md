---
layout: post
title: Kubernates集群部署
date: 2016-10-01 05:03:17 +0800
description: 在虚拟机上部署 Kubernetes
tags: [Kubernetes]
---

#### kubernetes结构图  
![kubernetes](../assets/img/kube-arch.png)  
（注：图片来自于infoq.com）  
#### 软件环境：
1. centos 7 （Linux 3.10）  
2. docker 1.12.1  
3. kubernetes  1.3.7  
4. flannel 0.5.3  
5. etcd 2.3.7  

#### 硬件环境：
1. master 一台centos7服务器(10.0.0.50)
2. minion 两台centos7服务器(10.0.0.51，10.0.0.52)

#### 安装说明：
docker负责容器管理  
kubernetes负责集群管理  
flannel负责承载集群网络，实现所有minion上的所有container之间的网络互通  
etcd负责存储kubernetes和flannel的数据  

为了避免ip设置，使用以下域名：  
etcd.local 指向etcd数据库  
master.local 指向kubernetes的master服务器  
dns.local 指向kubedns的服务器  
hub.local 指向docker私有源的服务器  

#### 1.在master和minion上安装Docker  
在yum中添加Docker源：/etc/yum.repos.d/docker.repo
```bash
[dockerrepo]
name=Docker Repository
baseurl=https://yum.dockerproject.org/repo/main/centos/7/
enabled=1
gpgcheck=1
gpgkey=https://yum.dockerproject.org/gpg
```
安装Docker：
```bash
yum install docker-engine
```

#### 2.在master上安装etcd && 在minion上安装flannel  
```bash
#只需要在master上安装
yum install etcd
#只需要在minion上安装
yum install flannel
```

#### 3.安装kubernetes  
下载kubernetes.tar.gz ：[https://github.com/kubernetes/kubernetes/releases](https://github.com/kubernetes/kubernetes/releases)    
kubernetes.tar.gz 中包含了已经编译过的二进制文件，找到其中适用于linux的hypercube和kube-dns  
将hypercube复制到所有服务器的/usr/local/bin中  
将kube-dns复制到master的/usr/local/bin    


#### 4.在master上安装Docker私有源
下载docker私有源镜像：[https://hub.docker.com/\_/registry/](https://hub.docker.com/\_/registry/)  
下载pause镜像：[https://hub.docker.com/r/google/pause/](https://hub.docker.com/r/google/pause/)
```bash
docker pull registry
docker pull google/pause
```
由于Docker pull镜像需要使用https，因此先创建证书：
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
其中使用私有源默认监听5000端口，为了方便使用域名直接访问，在此处映射到host的443端口上。  
将google/pause镜像上传到私有源中：  
```bash
docker tag google/pause hub.local/pause
#push失败则按第5步中说明先添加证书到信任列表
docker push hub.local/pause
```
google/pause是kubernetes需要的基本镜像，kubernetes在启动一个pod时，会先运行pause镜像，然后将pod定义的其他容器挂到pause上，以使用相同的ip。 


#### 5.配置master和minion服务器
将cert.pem导入到master和minion服务器的证书信任列表中：    
```bash
cat cert.pem >> /etc/pki/tls/certs/ca-bundle.crt
```
修改master和minion服务器的/etc/hosts文件，导入域名并指向master的ip：
```bash
echo 10.0.0.50 etcd.local >> /etc/hosts
echo 10.0.0.50 master.local >> /etc/hosts
echo 10.0.0.50 dns.local >> /etc/hosts
echo 10.0.0.50 hub.local >> /etc/hosts
```

#### 6.在master上启动etcd
```bash
service etcd start
```
添加flannel要使用的子网的key
```bash
etcdctl mk /flannel/network/config '{"Network":"10.254.0.0/16"}'
```

#### 7.在minion上启动flannel和dockerd
在所有的minion上执行：
```bash
flanneld -etcd-endpoints=http://etcd.local:2379 -etcd-prefix=/flannel/network
```
此时启动了flanneld，flanneld会从http://etcd.local:2379指向的etcd数据库中找到/flannel/network的key，然后根据Network指定的子网分配当前host可用的子网，并将分配到的子网信息存储在host的/run/flannel/docker文件中。  
子网分配成功后，即可启动dockerd
```bash
#使用/run/flannel/docker中定义的全局变量来启动
source /run/flannel/docker
dockerd ${DOCKER_NETWORK_OPTIONS}
```


#### 8.启动master上的kubernetes服务
```bash
#启动api服务
hyperkube apiserver --etcd-servers=http://etcd.local:2379 \
 --logtostderr=true \
 --v=0 \
 --allow-privileged=false \
 --insecure-bind-address=0.0.0.0 \
 --insecure-port=8080 \
 --service-cluster-ip-range=10.254.0.0/16 \
 --logtostderr=false \
 --log-dir=/root/logs/apiserver/&

#启动控制器管理器
hyperkube controller-manager --master=http://master.local:8080 \
 --logtostderr=false \
 --log-dir=/root/logs/controllermanager/&

#启动调度器
hyperkube scheduler --master=http://master.local:8080 \
 --logtostderr=false \
 --log-dir=/root/logs/scheduler/&

#启动dns，minion设置该dns后在pod中就可以使用服务域名来访问相应的服务
kube-dns --domain=kube.local --kube-master-url=http://master.local:8080 \
 --logtostderr=false \
 --log-dir=/root/logs/dns/ &

```

#### 9.启动minion上的kubernetes服务
```bash
#启动kubelet
hyperkube kubelet --address=0.0.0.0 \
 --port=10250 \
 --hostname-override=10.0.0.51 \
 --api-servers=http://master.local:8080 \
 --cluster-dns=dns.local \
 --cluster-domain=kube.local \
 --pod-infra-container-image=hub.local/pause \
 --logtostderr=false \
 --log-dir=/root/logs/kubelet/ &


#启动proxy
hyperkube proxy --master=http://master.local:8080 \
 --logtostderr=false \
 --log-dir=/root/logs/proxy/ &
```
