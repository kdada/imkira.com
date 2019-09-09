---
layout: post
title: Docker Registry manifest 分析
date: 2016-10-20 12:33:11 +0800
description: Docker Registry manifest 代码分析
tags: [Docker]
---

#### 分析环境：
distribution：https://github.com/docker/distribution  
branch：release/2.5  

#### 1.imageManifestDispatcher
imageManifestDispatcher 是注册在 [App](http://imkira.com/a6.html) 内的 Dispatcher，实现了处理 Manifest 的方法的调度方法。Dispatcher 处理 /v2/{name}/manifests/{reference} 形式的请求（/registry/api/v2/desriptors.go#491），并生成对应于不同 Http Method 的 Handler，最终交由 Handler 处理请求。  
imageManifestDispatcher：/registry/handlers/images.go#30  
```go
// imageManifestDispatcher 根据请求的类型生成相应的 Handler
func imageManifestDispatcher(ctx *Context, r *http.Request) http.Handler {
    imageManifestHandler := &imageManifestHandler{
        Context: ctx,
    }
    //reference 为 repo 的的 tag 或 manifest 的标识符
    reference := getReference(ctx)
    // 检查 refrence 是否能够转换为 Digest(manifest 的标识符是 Digest 形式的字符串)
    dgst, err := digest.ParseDigest(reference)
    if err != nil {
        // 如果 reference 格式不符, 则视 reference 为 Tag
        imageManifestHandler.Tag = reference
    } else {
        // 如果 reference 格式符合, 则视 reference 为 Digest
        imageManifestHandler.Digest = dgst
    }
    // 添加 GET 和 HEAD 请求的 Handler
    mhandler := handlers.MethodHandler{
        "GET":  http.HandlerFunc(imageManifestHandler.GetImageManifest),
        "HEAD": http.HandlerFunc(imageManifestHandler.GetImageManifest),
    }
    // 如果 readOnly 为 false 表示可以处理写请求, 则添加 PUT 和 DELETE 请求的 Handler
    if !ctx.readOnly {
        //PutImageManifest 上传并存储 Manifest, 并根据请求的参数设置 Tag
        mhandler["PUT"] = http.HandlerFunc(imageManifestHandler.PutImageManifest)
        //DeleteImageManifest 从 registry 中删除指定的以及其关联的 Manifest
        // 同时将与 Manifest 关联的各个 Tag 一并删除
        mhandler["DELETE"] = http.HandlerFunc(imageManifestHandler.DeleteImageManifest)
    }
    return mhandler
}
```

#### 2.imageManifestDispatcher context.Repository 属性分析
imageManifestDispatcher 在 App.register 中被 App.dispatcher 包装，并生成关键的 Context 对象
```go
// dispatcher:/registry/handlers/app.go#592
func (app *App) dispatcher(dispatch dispatchFunc) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        ...
        //nameRequired 用于检查当前请求是否需要使用 name 属性
        //imageManifestDispatcher 使用 name 属性作为 repo 名称, 因此会为该请求的 Context 创建 repository 等信息
        if app.nameRequired(r) {
            //getName 获取 url 中的 name 信息, 该 name 为 repo 的名称
            nameRef, err := reference.ParseNamed(getName(context))
            ...

            //registry 为 storage.registry:/registry/storage/registry.go#14
            // 使用 registry 创建 repository,repository 为 storage.repository:/registry/storage/registry.go#158
            //repository.name 为 repo 的名称
            repository, err := app.registry.Repository(context, nameRef)
            ...

            // 该 context 为 handlers.Context:/registry/handlers/context.go
            context.Repository = notifications.Listen(
                repository,
                app.eventBridge(context, r))
            ...
        }
        // 将 context 传递给 dispatch, 此时 context 内部包含了 registry,repository 实例
        dispatch(context, r).ServeHTTP(w, r)
        ...
    })
}

// Manifests 根据当前的 repo 生成 ManifestService /registry/storage/registry.go#182
func (repo *repository) Manifests(ctx context.Context, options ...distribution.ManifestServiceOption) (distribution.ManifestService, error) {
    ...

    //blob 存储实例, 用于读取 blob
    blobStore := &linkedBlobStore{
        ctx:                  ctx,
        blobStore:            repo.blobStore,
        repository:           repo,
        deleteEnabled:        repo.registry.deleteEnabled,
        blobAccessController: statter,

        // TODO(stevvooe): linkPath limits this blob store to only
        // manifests. This instance cannot be used for blob checks.
        linkPathFns:           manifestLinkPathFns,
        linkDirectoryPathSpec: manifestDirectoryPathSpec,
    }

    // 创建 manifestStore, 用于读取 manifest
    ms := &manifestStore{
        ctx:        ctx,
        repository: repo,
        blobStore:  blobStore,
        schema1Handler: &signedManifestHandler{
            ctx:        ctx,
            repository: repo,
            blobStore:  blobStore,
        },
        schema2Handler: &schema2ManifestHandler{
            ctx:        ctx,
            repository: repo,
            blobStore:  blobStore,
        },
        manifestListHandler: &manifestListHandler{
            ctx:        ctx,
            repository: repo,
            blobStore:  blobStore,
        },
    }
    ...

    return ms, nil
}

// Get 获取指定的 manifest /registry/storage/manifeststore.go#70
func (ms *manifestStore) Get(ctx context.Context, dgst digest.Digest, options ...distribution.ManifestServiceOption) (distribution.Manifest, error) {
    // 获取 Digest 指向的数据
    content, err := ms.blobStore.Get(ctx, dgst)
    if err != nil {
        if err == distribution.ErrBlobUnknown {
            return nil, distribution.ErrManifestUnknownRevision{
                Name:     ms.repository.Named().Name(),
                Revision: dgst,
            }
        }

        return nil, err
    }
    // 将读取出的 content 解析到 Versioned 实例
    var versioned manifest.Versioned
    if err = json.Unmarshal(content, &versioned); err != nil {
        return nil, err
    }

    // 根据版本解析到不同的类型中
    switch versioned.SchemaVersion {
    case 1:
        return ms.schema1Handler.Unmarshal(ctx, dgst, content)
    case 2:
        // This can be an image manifest or a manifest list
        switch versioned.MediaType {
        case schema2.MediaTypeManifest:
            return ms.schema2Handler.Unmarshal(ctx, dgst, content)
        case manifestlist.MediaTypeManifestList:
            return ms.manifestListHandler.Unmarshal(ctx, dgst, content)
        default:
            return nil, distribution.ErrManifestVerification{fmt.Errorf("unrecognized manifest content type %s", versioned.MediaType)}
        }
    }

    return nil, fmt.Errorf("unrecognized manifest schema version %d", versioned.SchemaVersion)
}
```
#### 3.imageManifestHandler.GetImageManifest 获取 image 的 manifest 兼容性分析
一个 manifest 范例：
```json
{
   "schemaVersion": 2,
   "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
   "config": {
      "mediaType": "application/vnd.docker.container.image.v1+json",
      "size": 2941,
      "digest": "sha256:c1061fcd6f18076c66e3136c2b7b0671d8dac53069db5e645fe5c41bd1c720df"
   },
   "layers": [
      {
         "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
         "size": 70591526,
         "digest": "sha256:8d30e94188e7f13642d975e70c484e48c33867f3ede3277df1145803fa996ac1"
      },
      {
         "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
         "size": 1074069567,
         "digest": "sha256:4682f625c356560bd2dc2f26dfc9af5ded0fb0aa5e301e1afd33c38340acf95a"
      },
      {
         "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
         "size": 1074069566,
         "digest": "sha256:d138e90cf64401783f3682e74c519ecb33dd020298a90c7ae737cdf98f334258"
      }
   ]
}
```

```go
// GetImageManifest 获取指定 image 的 manifest
func (imh *imageManifestHandler) GetImageManifest(w http.ResponseWriter, r *http.Request) {
    ctxu.GetLogger(imh).Debug("GetImageManifest")
    // 从 Repository 中获取 Manifests 服务
    manifests, err := imh.Repository.Manifests(imh)
    if err != nil {
        imh.Errors = append(imh.Errors, err)
        return
    }

    var manifest distribution.Manifest
    if imh.Tag != "" {
        // 如果 Tag 不为空, 则说明请求传递了 Tag
        // 根据 Tag 获取对应的 Digest
        tags := imh.Repository.Tags(imh)
        desc, err := tags.Get(imh, imh.Tag)
        if err != nil {
            imh.Errors = append(imh.Errors, v2.ErrorCodeManifestUnknown.WithDetail(err))
            return
        }
        imh.Digest = desc.Digest
    }
    ...
    
    // 无论请求传递的 refrence 是 Tag 还是 Digest, 到这里都会变成 Digest
    // 根据 Digest 获取指定的 manifest
    manifest, err = manifests.Get(imh, imh.Digest, options...)
    if err != nil {
        imh.Errors = append(imh.Errors, v2.ErrorCodeManifestUnknown.WithDetail(err))
        return
    }
    // 根据请求头的 Accept 检查客户端对 Schema2 和 ManifestList 的支持情况
    supportsSchema2 := false
    supportsManifestList := false
    for _, acceptHeader := range r.Header["Accept"] {
        for _, mediaType := range strings.Split(acceptHeader, ",") {
            if i := strings.Index(mediaType, ";"); i >= 0 {
                mediaType = mediaType[:i]
            }
            mediaType = strings.TrimSpace(mediaType)
            if mediaType == schema2.MediaTypeManifest {
                supportsSchema2 = true
            }
            if mediaType == manifestlist.MediaTypeManifestList {
                supportsManifestList = true
            }
        }
    }
    // 检查 manifests.Get 返回的 manifest 的类型, registry 默认用 Schema2 进行存储
    schema2Manifest, isSchema2 := manifest.(*schema2.DeserializedManifest)
    manifestList, isManifestList := manifest.(*manifestlist.DeserializedManifestList)

    // 检查 manifest 的版本以及客户端支持的版本
    if imh.Tag != "" && isSchema2 && !supportsSchema2 {
        // 如果当前 manifest 是 Schema2 的同时客户端不支持, 则使用 convertSchema2Manifest 方法将 manifest 转换为 Schema1 的版本
        manifest, err = imh.convertSchema2Manifest(schema2Manifest)
        if err != nil {
            return
        }
    } else if imh.Tag != "" && isManifestList && !supportsManifestList {
        // 如果当前 manifest 是 ManifestList 的同时客户端不支持, 则选择默认 OS 版本的 manifest 的返回
        var manifestDigest digest.Digest
        for _, manifestDescriptor := range manifestList.Manifests {
            if manifestDescriptor.Platform.Architecture == defaultArch && manifestDescriptor.Platform.OS == defaultOS {
                manifestDigest = manifestDescriptor.Digest
                break
            }
        }

        if manifestDigest == "" {
            imh.Errors = append(imh.Errors, v2.ErrorCodeManifestUnknown)
            return
        }

        manifest, err = manifests.Get(imh, manifestDigest)
        if err != nil {
            imh.Errors = append(imh.Errors, v2.ErrorCodeManifestUnknown.WithDetail(err))
            return
        }

        // 如果当前 manifest 是 Schema2 的同时客户端不支持, 则使用 convertSchema2Manifest 方法将 manifest 转换为 Schema1 的版本
        if schema2Manifest, isSchema2 := manifest.(*schema2.DeserializedManifest); isSchema2 && !supportsSchema2 {
            manifest, err = imh.convertSchema2Manifest(schema2Manifest)
            if err != nil {
                return
            }
        }
    }
    // 生成 manifest 数据返回给客户端
    ct, p, err := manifest.Payload()
    if err != nil {
        return
    }

    w.Header().Set("Content-Type", ct)
    w.Header().Set("Content-Length", fmt.Sprint(len(p)))
    w.Header().Set("Docker-Content-Digest", imh.Digest.String())
    w.Header().Set("Etag", fmt.Sprintf(`"%s"`, imh.Digest))
    w.Write(p)
}
```
备注：Schema2 只返回了简单的 manifest, 还需要根据 config.digest 属性中指定的 sha256 值获取详细的信息, 而经过 convertSchema2Manifest 转换成 Schema1 版本的 manifest 已经包含了详细信息。
