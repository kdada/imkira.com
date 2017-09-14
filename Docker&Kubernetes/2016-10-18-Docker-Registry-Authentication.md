---
layout: post
title: Registry鉴权验证分析
date: 2016-10-18 12:06:39 +0800
description: Docker Registry 鉴权验证代码分析
tags: [Docker]
---

#### 分析环境：
distribution：https://github.com/docker/distribution  
branch：release/2.5  

#### 1.Registry启动
##### main文件：/cmd/registry/main.go
```go
func main() {
    //执行RootCmd
    registry.RootCmd.Execute()
}
```
##### RootCmd：/registry/root.go
```go
//registry包初始化函数
func init() {
    //将serve命令添加到Root命令中
    //可以通过 registry serve 使用serve命令
    //registry是编译后的生成的二进制文件,可能是其他名称
    RootCmd.AddCommand(ServeCmd)
    ...
}

// RootCmd is the main command for the 'registry' binary.
// RootCmd是registry应用的根命令
var RootCmd = &cobra.Command{
    ...
}
```
##### ServeCmd：/registry/registry.go
```go
// ServeCmd is a cobra command for running the registry.
// ServeCmd 用于启动registry
var ServeCmd = &cobra.Command{
    // serve命令需要指定配置文件
    Use:   "serve <config>",
    Short: "`serve` stores and distributes Docker images",
    Long:  "`serve` stores and distributes Docker images.",
    Run: func(cmd *cobra.Command, args []string) {

        // setup context
        ctx := context.WithVersion(context.Background(), version.Version)
        //解析配置文件并生成配置
        config, err := resolveConfiguration(args)
        if err != nil {
            fmt.Fprintf(os.Stderr, "configuration error: %v\n", err)
            cmd.Usage()
            os.Exit(1)
        }
        //检查是否开启调试模式
        if config.HTTP.Debug.Addr != "" {
            go func(addr string) {
                log.Infof("debug server listening %v", addr)
                if err := http.ListenAndServe(addr, nil); err != nil {
                    log.Fatalf("error listening on debug interface: %v", err)
                }
            }(config.HTTP.Debug.Addr)
        }
        //创建registry实例
        registry, err := NewRegistry(ctx, config)
        if err != nil {
            log.Fatalln(err)
        }
        //registry启动,启动后即可接受docker daemon的请求
        if err = registry.ListenAndServe(); err != nil {
            log.Fatalln(err)
        }
    },
}
```
#### 2.Registry分析
##### Registry：/registry/registry.go#68
```go
type Registry struct {
    config *configuration.Configuration
    app    *handlers.App
    server *http.Server
}

// NewRegistry 根据指定的Context和Configuration创建registry实例
func NewRegistry(ctx context.Context, config *configuration.Configuration) (*Registry, error) {
    ...
    //根据配置创建App(包含多个handler),鉴权验证在app中处理
    app := handlers.NewApp(ctx, config)

    //对app的ServeHTTP进行多层的包装
    app.RegisterHealthChecks()
    handler := configureReporting(app)
    handler = alive("/", handler)
    handler = health.Handler(handler)
    handler = panicHandler(handler)
    handler = gorhandlers.CombinedLoggingHandler(os.Stdout, handler)

    //创建http服务
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
// NewApp根据配置生成App实例,App实例拥有ServeHTTP函数,可以处理相应的http请求
func NewApp(ctx context.Context, config *configuration.Configuration) *App {

    //在app中注册系列路由
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
    //从配置文件中读取鉴权验证类型 #262
    authType := config.Auth.Type()
    if authType != "" {
        //获取指定authType的访问控制器
        accessController, err := auth.GetAccessController(config.Auth.Type(), config.Auth.Parameters())
        if err != nil {
            panic(fmt.Sprintf("unable to configure authorization (%s): %v", authType, err))
        }
        //设置app的accessController属性
        app.accessController = accessController
        ctxu.GetLogger(app).Debugf("configured %q access controller", authType)
    }
    ...
}

//注册routeName路由,并使用app.dispatcher方法对dispatch方法进行包装
func (app *App) register(routeName string, dispatch dispatchFunc) {
    app.router.GetRoute(routeName).Handler(app.dispatcher(dispatch))
}

//包装dispatch为http.Handler
func (app *App) dispatcher(dispatch dispatchFunc) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        ...
        //对请求进行authorized验证
        if err := app.authorized(w, r, context); err != nil {
            ctxu.GetLogger(context).Warnf("error authorizing context: %v", err)
            return
        }
        ...
        //调用真正的dispatch方法
        dispatch(context, r).ServeHTTP(w, r)
        ...
    })
}

//鉴权验证方法
func (app *App) authorized(w http.ResponseWriter, r *http.Request, context *Context) error {
    ...
    //app.accessController是App创建时根据配置文件生成的
    //调用app.accessController.Authorized方法进行验证
    ctx, err := app.accessController.Authorized(context.Context, accessRecords...)
    if err != nil {
        switch err := err.(type) {
        case auth.Challenge:
            //当app.accessController.Authorized返回auth.Challenge类型的错误时
            //将设置WWW-Auth头,告知client需要进行鉴权验证
            err.SetHeaders(w)
            //返回错误信息
            if err := errcode.ServeJSON(w, errcode.ErrorCodeUnauthorized.WithDetail(accessRecords)); err != nil {
                ctxu.GetLogger(context).Errorf("error serving error json: %v (from %v)", err, context.Errors)
            }
        default:
            //其他情况返回400错误
            ctxu.GetLogger(context).Errorf("error checking authorization: %v", err)
            w.WriteHeader(http.StatusBadRequest)
        }
        return err
    }
    context.Context = ctx
    return nil
}
```

在配置文件中可以指定访问控制器(AccessController)的类型。目前存在三种类型的鉴权验证类型：
1. htpasswd：/registry/auth/htpasswd.go#96
2. silly：/registry/auth/silly.go#96
3. token：/registry/auth/token.go#267

#### 3.请求鉴权过程描述
1. 当新请求到达时，由registry.server.Handler处理
2. 请求经过registry.app外层的handler后进入app.ServeHTTP
3. app.ServeHTTP调用app.router.ServeHTTP
4. app.router根据路由查找到相应的handler,该handler被app.dispatcher包装过
5. 执行app.dispatcher内部的包装方法,然后使用app.authorized进行验证
6. app.authorized会调用配置中指定的accessController的Authorized方法进行验证
7. 根据验证结果确定是直接返回错误还是继续执行

#### 4.token类型鉴权分析
##### token.accessController：/registry/auth/token.go#215
```go
func (ac *accessController) Authorized(ctx context.Context, accessItems ...auth.Access) (context.Context, error) {
    //创建Challenge类型的错误
    //该Challenge返回的WWW-Auth头字符串格式如下
    //Bearer realm=%q,service=%q[,scope=%q[,error=%q]]
    challenge := &authChallenge{
        realm:     ac.realm,//一个url,用于告知client应该去哪里获取鉴权的Token
        service:   ac.service,
        accessSet: newAccessSet(accessItems...),
    }
    //从context中获取request实例
    req, err := context.GetRequest(ctx)
    if err != nil {
        return nil, err
    }
    //从请求头中获取Authorization并根据空格分割
    parts := strings.Split(req.Header.Get("Authorization"), " ")
    //Authorization token格式验证
    if len(parts) != 2 || strings.ToLower(parts[0]) != "bearer" {
        challenge.err = ErrTokenRequired
        return nil, challenge
    }
    //获取Authorization的token部分
    rawToken := parts[1]

    //创建Token实例
    token, err := NewToken(rawToken)
    if err != nil {
        challenge.err = err
        return nil, challenge
    }
    //设定验证选项
    verifyOpts := VerifyOptions{
        TrustedIssuers:    []string{ac.issuer},
        AcceptedAudiences: []string{ac.service},
        Roots:             ac.rootCerts,//根证书
        TrustedKeys:       ac.trustedKeys,//可信密钥
    }
    //对Token进行验证,判断token是否是正确的
    if err = token.Verify(verifyOpts); err != nil {
        challenge.err = err
        return nil, challenge
    }
    //从token中获取可以访问的权限范围
    accessSet := token.accessSet()
    //检查请求的权限是否符合要求
    for _, access := range accessItems {
        if !accessSet.contains(access) {
            challenge.err = ErrInsufficientScope
            return nil, challenge
        }
    }

    return auth.WithUser(ctx, auth.UserInfo{Name: token.Claims.Subject}), nil
}
```
