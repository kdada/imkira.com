---
layout: post
title: Docker Registry 鉴权验证分析
date: 2016-10-18 12:06:39 +0800
description: Docker Registry 鉴权验证代码分析
tags: [Docker]
---

#### 分析环境：
distribution：https://github.com/docker/distribution  
branch：release/2.5  

#### 1.Registry 启动
##### main 文件：/cmd/registry/main.go
```go
func main() {
    // 执行 RootCmd
    registry.RootCmd.Execute()
}
```
##### RootCmd：/registry/root.go
```go
//registry 包初始化函数
func init() {
    // 将 serve 命令添加到 Root 命令中
    // 可以通过 registry serve 使用 serve 命令
    //registry 是编译后的生成的二进制文件, 可能是其他名称
    RootCmd.AddCommand(ServeCmd)
    ...
}

// RootCmd is the main command for the 'registry' binary.
// RootCmd 是 registry 应用的根命令
var RootCmd = &cobra.Command{
    ...
}
```
##### ServeCmd：/registry/registry.go
```go
// ServeCmd is a cobra command for running the registry.
// ServeCmd 用于启动 registry
var ServeCmd = &cobra.Command{
    // serve 命令需要指定配置文件
    Use:   "serve <config>",
    Short: "`serve` stores and distributes Docker images",
    Long:  "`serve` stores and distributes Docker images.",
    Run: func(cmd *cobra.Command, args []string) {

        // setup context
        ctx := context.WithVersion(context.Background(), version.Version)
        // 解析配置文件并生成配置
        config, err := resolveConfiguration(args)
        if err != nil {
            fmt.Fprintf(os.Stderr, "configuration error: %v\n", err)
            cmd.Usage()
            os.Exit(1)
        }
        // 检查是否开启调试模式
        if config.HTTP.Debug.Addr != "" {
            go func(addr string) {
                log.Infof("debug server listening %v", addr)
                if err := http.ListenAndServe(addr, nil); err != nil {
                    log.Fatalf("error listening on debug interface: %v", err)
                }
            }(config.HTTP.Debug.Addr)
        }
        // 创建 registry 实例
        registry, err := NewRegistry(ctx, config)
        if err != nil {
            log.Fatalln(err)
        }
        //registry 启动, 启动后即可接受 docker daemon 的请求
        if err = registry.ListenAndServe(); err != nil {
            log.Fatalln(err)
        }
    },
}
```
#### 2.Registry 分析
##### Registry：/registry/registry.go#68
```go
type Registry struct {
    config *configuration.Configuration
    app    *handlers.App
    server *http.Server
}

// NewRegistry 根据指定的 Context 和 Configuration 创建 registry 实例
func NewRegistry(ctx context.Context, config *configuration.Configuration) (*Registry, error) {
    ...
    // 根据配置创建 App(包含多个 handler), 鉴权验证在 app 中处理
    app := handlers.NewApp(ctx, config)

    // 对 app 的 ServeHTTP 进行多层的包装
    app.RegisterHealthChecks()
    handler := configureReporting(app)
    handler = alive("/", handler)
    handler = health.Handler(handler)
    handler = panicHandler(handler)
    handler = gorhandlers.CombinedLoggingHandler(os.Stdout, handler)

    // 创建 http 服务
    server := &http.Server{
        Handler: handler,
    }

    return &Registry{
        app:    app,
        config: config,
        server: server,
    }, nil
}
```
##### App：/registry/handlers/app.go#89
```go
// NewApp takes a configuration and returns a configured app, ready to serve
// requests. The app only implements ServeHTTP and can be wrapped in other
// handlers accordingly.
// NewApp 根据配置生成 App 实例, App 实例拥有 ServeHTTP 函数, 可以处理相应的 http 请求
func NewApp(ctx context.Context, config *configuration.Configuration) *App {

    // 在 app 中注册系列路由
    app.register(v2.RouteNameBase, func(ctx *Context, r *http.Request) http.Handler {
        return http.HandlerFunc(apiBase)
    })
    app.register(v2.RouteNameManifest, imageManifestDispatcher)
    app.register(v2.RouteNameCatalog, catalogDispatcher)
    app.register(v2.RouteNameTags, tagsDispatcher)
    app.register(v2.RouteNameBlob, blobDispatcher)
    app.register(v2.RouteNameBlobUpload, blobUploadDispatcher)
    app.register(v2.RouteNameBlobUploadChunk, blobUploadDispatcher)
    ...
    // 从配置文件中读取鉴权验证类型 #262
    authType := config.Auth.Type()
    if authType != "" {
        // 获取指定 authType 的访问控制器
        accessController, err := auth.GetAccessController(config.Auth.Type(), config.Auth.Parameters())
        if err != nil {
            panic(fmt.Sprintf("unable to configure authorization (%s): %v", authType, err))
        }
        // 设置 app 的 accessController 属性
        app.accessController = accessController
        ctxu.GetLogger(app).Debugf("configured %q access controller", authType)
    }
    ...
}

// 注册 routeName 路由, 并使用 app.dispatcher 方法对 dispatch 方法进行包装
func (app *App) register(routeName string, dispatch dispatchFunc) {
    app.router.GetRoute(routeName).Handler(app.dispatcher(dispatch))
}

// 包装 dispatch 为 http.Handler
func (app *App) dispatcher(dispatch dispatchFunc) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        ...
        // 对请求进行 authorized 验证
        if err := app.authorized(w, r, context); err != nil {
            ctxu.GetLogger(context).Warnf("error authorizing context: %v", err)
            return
        }
        ...
        // 调用真正的 dispatch 方法
        dispatch(context, r).ServeHTTP(w, r)
        ...
    })
}

// 鉴权验证方法
func (app *App) authorized(w http.ResponseWriter, r *http.Request, context *Context) error {
    ...
    //app.accessController 是 App 创建时根据配置文件生成的
    // 调用 app.accessController.Authorized 方法进行验证
    ctx, err := app.accessController.Authorized(context.Context, accessRecords...)
    if err != nil {
        switch err := err.(type) {
        case auth.Challenge:
            // 当 app.accessController.Authorized 返回 auth.Challenge 类型的错误时
            // 将设置 WWW-Auth 头, 告知 client 需要进行鉴权验证
            err.SetHeaders(w)
            // 返回错误信息
            if err := errcode.ServeJSON(w, errcode.ErrorCodeUnauthorized.WithDetail(accessRecords)); err != nil {
                ctxu.GetLogger(context).Errorf("error serving error json: %v (from %v)", err, context.Errors)
            }
        default:
            // 其他情况返回 400 错误
            ctxu.GetLogger(context).Errorf("error checking authorization: %v", err)
            w.WriteHeader(http.StatusBadRequest)
        }
        return err
    }
    context.Context = ctx
    return nil
}
```

在配置文件中可以指定访问控制器 (AccessController) 的类型。目前存在三种类型的鉴权验证类型：
1. htpasswd：/registry/auth/htpasswd.go#96
2. silly：/registry/auth/silly.go#96
3. token：/registry/auth/token.go#267

#### 3. 请求鉴权过程描述
1. 当新请求到达时，由 registry.server.Handler 处理
2. 请求经过 registry.app 外层的 handler 后进入 app.ServeHTTP
3. app.ServeHTTP 调用 app.router.ServeHTTP
4. app.router 根据路由查找到相应的 handler, 该 handler 被 app.dispatcher 包装过
5. 执行 app.dispatcher 内部的包装方法, 然后使用 app.authorized 进行验证
6. app.authorized 会调用配置中指定的 accessController 的 Authorized 方法进行验证
7. 根据验证结果确定是直接返回错误还是继续执行

#### 4.token 类型鉴权分析
##### token.accessController：/registry/auth/token.go#215
```go
func (ac *accessController) Authorized(ctx context.Context, accessItems ...auth.Access) (context.Context, error) {
    // 创建 Challenge 类型的错误
    // 该 Challenge 返回的 WWW-Auth 头字符串格式如下
    //Bearer realm=%q,service=%q[,scope=%q[,error=%q]]
    challenge := &authChallenge{
        realm:     ac.realm,// 一个 url, 用于告知 client 应该去哪里获取鉴权的 Token
        service:   ac.service,
        accessSet: newAccessSet(accessItems...),
    }
    // 从 context 中获取 request 实例
    req, err := context.GetRequest(ctx)
    if err != nil {
        return nil, err
    }
    // 从请求头中获取 Authorization 并根据空格分割
    parts := strings.Split(req.Header.Get("Authorization"), " ")
    //Authorization token 格式验证
    if len(parts) != 2 || strings.ToLower(parts[0]) != "bearer" {
        challenge.err = ErrTokenRequired
        return nil, challenge
    }
    // 获取 Authorization 的 token 部分
    rawToken := parts[1]

    // 创建 Token 实例
    token, err := NewToken(rawToken)
    if err != nil {
        challenge.err = err
        return nil, challenge
    }
    // 设定验证选项
    verifyOpts := VerifyOptions{
        TrustedIssuers:    []string{ac.issuer},
        AcceptedAudiences: []string{ac.service},
        Roots:             ac.rootCerts,// 根证书
        TrustedKeys:       ac.trustedKeys,// 可信密钥
    }
    // 对 Token 进行验证, 判断 token 是否是正确的
    if err = token.Verify(verifyOpts); err != nil {
        challenge.err = err
        return nil, challenge
    }
    // 从 token 中获取可以访问的权限范围
    accessSet := token.accessSet()
    // 检查请求的权限是否符合要求
    for _, access := range accessItems {
        if !accessSet.contains(access) {
            challenge.err = ErrInsufficientScope
            return nil, challenge
        }
    }

    return auth.WithUser(ctx, auth.UserInfo{Name: token.Claims.Subject}), nil
}
```
