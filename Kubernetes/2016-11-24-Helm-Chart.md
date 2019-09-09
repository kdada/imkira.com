---
layout: post
title: Helm Chart 结构
date: 2016-11-24 12:03:37 +0800
description: Kubernetes Helm Chart 介绍
tags: [Helm, Kubernetes]
---
 
#### Chart 目录结构
```
examples/
  Chart.yaml          # Yaml 文件，用于描述 Chart 的基本信息，包括名称版本等
  LICENSE             # [可选] 协议
  README.md           # [可选] 当前 Chart 的介绍
  values.yaml         # Chart 的默认配置文件
  requirements.yaml   # [可选] 用于存放当前 Chart 依赖的其它 Chart 的说明文件
  charts/             # [可选]: 该目录中放置当前 Chart 依赖的其它 Chart
  templates/          # [可选]: 部署文件模版目录，模版使用的值来自 values.yaml 和由 Tiller 提供的值
  templates/NOTES.txt # [可选]: 放置 Chart 的使用指南
```

#### Chart.yaml 文件
```
name: [必须] Chart 的名称
version: [必须] Chart 的版本号，版本号必须符合 SemVer 2：http://semver.org/
description: [可选] Chart 的简要描述
keywords:
  -  [可选] 关键字列表
home: [可选] 项目地址
sources:
  - [可选] 当前 Chart 的下载地址列表
maintainers: # [可选]
  - name: [必须] 名字
    email: [可选] 邮箱
engine: gotpl # [可选] 模版引擎，默认值是 gotpl
icon: [可选] 一个 SVG 或 PNG 格式的图片地址
```

#### requirements.yaml 和 charts 目录
requirements.yaml 文件内容：
```
dependencies:
  - name: example
    version: 1.2.3
    repository: http://example.com/charts
  - name: Chart 名称
    version: Chart 版本
    repository: 该 Chart 所在的仓库地址
```
Chart 支持两种方式表示依赖关系，可以使用 requirements.yaml 或者直接将依赖的 Chart 放置到 charts 目录中。  

#### templates 目录
templates 目录中存放了 Kubernetes 部署文件的模版。  
例如：  
```
# db.yaml
apiVersion: v1
kind: ReplicationController
metadata:
  name: deis-database
  namespace: deis
  labels:
    heritage: deis
spec:
  replicas: 1
  selector:
    app: deis-database
  template:
    metadata:
      labels:
        app: deis-database
    spec:
      serviceAccount: deis-database
      containers:
        - name: deis-database
          image: {{.Values.imageRegistry}}/postgres:{{.Values.dockerTag}}
          imagePullPolicy: {{.Values.pullPolicy}}
          ports:
            - containerPort: 5432
          env:
            - name: DATABASE_STORAGE
              value: {{default "minio" .Values.storage}}
```
模版语法扩展了 golang/text/template 的语法：  
```
# 这种方式定义的模版，会去除 test 模版尾部所有的空行
{{- define "test"}}
模版内容
{{- end}}

# 去除 test 模版头部的第一个空行
{{- template "test" }}
```
用于 yaml 文件前置空格的语法：
```
# 这种方式定义的模版，会去除 test 模版头部和尾部所有的空行
{{- define "test" -}}
模版内容
{{- end -}}

# 可以在 test 模版每一行的头部增加 4 个空格，用于 yaml 文件的对齐
{{ include "test" | indent 4}}

```
