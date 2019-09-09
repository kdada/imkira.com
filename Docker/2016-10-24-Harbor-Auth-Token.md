---
layout: post
title: Harbor Auth Token 分析
date: 2016-10-24 11:19:52 +0800
description: Harbor Auth Token 源码分析
tags: [Docker, Harbor]
---

#### 分析环境：
harbor：https://github.com/vmware/harbor  
Tags：0.4.1

#### 1.docker 鉴权请求分析
1.docker 直接 pull public repo，请求格式如下：
```
/service/token?scope=repository:test/repo:pull&service=token-service
```

2.docker pull private repo，请求格式如下：
```
/service/token?account=test&scope=repository:test/repo:push,pull&service=token-service
```
除此之外，对 private repo 的请求还会在 Request Header 中加入 Authorization
HTTP Basic Authentication 格式如下：
```
//account:password
Basic YWNjb3VudDpwYXNzd29yZA==
```
两个请求共有的部分如下：  
scope：指定类型（repository），repo（test/repo），请求的操作权限（pull && push）  
service：即 JWT 验证中的 Audience，Token 接收方（即 registry）  

#### 2.Harbor 权限获取源码分析
Harbor 路由：/service/token（/service/token/token.go#39）
```go
// Get 处理获取 Token 的请求
func (h *Handler) Get() {

    var username, password string
    request := h.Ctx.Request
    // 获取 JWT 接收方名称
    service := h.GetString("service")
    // 获取 scopes
    scopes := h.GetStrings("scope")
    // 根据 scopes 生成 ResourceActions 数组, 该结构体的定义位于 github.com/docker/distribution/registry/auth/token/token.go#32
    //type ResourceActions struct {
    //  Type    string   `json:"type"`// 资源类型, 此处为 repository
    //  Name    string   `json:"name"`// 资源名称, 即 repo 名称
    //  Actions []string `json:"actions"`// 资源可用权限数组, 即 pull,push
    //}
    access := GetResourceActions(scopes)
    log.Infof("request url: %v", request.URL.String())

    // 验证 Request 的 Cookie 中是否包含 uisecret, 其值为 Harbor 预定义的密钥
    // 该密钥在环境变量 UI_SECRET 中定义, 使用该密钥可以获得任意权限, 仅在 Harbor 的 Job Service 中使用
    if svc_utils.VerifySecret(request) {
        log.Debugf("Will grant all access as this request is from job service with legal secret.")
        username = "job-service-user"
    } else {
        // 从 HTTP Basic Authentication 中获取用户名密码
        username, password, _ = request.BasicAuth()
        // 验证用户名密码是否正确
        authenticated := authenticate(username, password)
        // 如果 scopes 为空并且用户不存在则直接终止请求
        if len(scopes) == 0 && !authenticated {
            log.Info("login request with invalid credentials")
            h.CustomAbort(http.StatusUnauthorized, "")
        }
        // 对用户请求的权限进行过滤, 确保用户不能获得不属于自身的权限
        for _, a := range access {
            FilterAccess(username, authenticated, a)
        }
    }
    // 根据用户名, 接收方名称, 可用权限生成 JWT
    h.serveToken(username, service, access)
}
```

FilterAccess 过滤方法：/service/token/authutils.go#99
```go
// FilterAccess 过滤用户请求的权限
func FilterAccess(username string, authenticated bool, a *token.ResourceActions) {
    // 对于 registry 类型并且名为 catalog 的请求不进行任何过滤
    if a.Type == "registry" && a.Name == "catalog" {
        log.Infof("current access, type: %s, name:%s, actions:%v \n", a.Type, a.Name, a.Actions)
        return
    }

    // 直接对 Actions 重新赋值, 无视用户请求的权限
    a.Actions = []string{}
    if a.Type == "repository" {
        if strings.Contains(a.Name, "/") {
            //Harbor 目前不允许创建带有 / 的 project,projectName 为 a.Name 到最后一个 / 之间的字符串
            // 因此 Harbor 中, 只能识别类似 test/repo 的两级 repo
            // 对于非 2 级的 repo 名称全部无法 push 和 pull
            // 例如 repo  test/xxx/repo 都是无效的 (虽然 docker 允许创建这种 Tag)
            projectName := a.Name[0:strings.LastIndex(a.Name, "/")]
            var permission string
            if authenticated {
                isAdmin, err := dao.IsAdminRole(username)
                if err != nil {
                    log.Errorf("Error occurred in IsAdminRole: %v", err)
                }
                if isAdmin {
                    exist, err := dao.ProjectExists(projectName)
                    if err != nil {
                        log.Errorf("Error occurred in CheckExistProject: %v", err)
                        return
                    }
                    if exist {
                        //Admin 对于任何存在的项目都拥有所有权限
                        permission = "RWM"
                    } else {
                        permission = ""log.Infof("project %s does not exist, set empty permission for admin\n", projectName)
                    }
                } else {
                    // 普通用户根据用户在项目中的 Role 获得不同的权限
                    //projectAdmin MDRWS
                    //developer RWS
                    //guest RS
                    permission, err = dao.GetPermission(username, projectName)
                    if err != nil {
                        log.Errorf("Error occurred in GetPermission: %v", err)
                        return
                    }
                }
            }
            //push 权限
            if strings.Contains(permission, "W") {
                a.Actions = append(a.Actions, "push")
            }
            // 管理权限
            if strings.Contains(permission, "M") {
                a.Actions = append(a.Actions, "*")
            }
            //pull 权限, 权限中包含 R 或者该 project 为 public 的
            if strings.Contains(permission, "R") || dao.IsProjectPublic(projectName) {
                a.Actions = append(a.Actions, "pull")
            }
        }
    }
    log.Infof("current access, type: %s, name:%s, actions:%v \n", a.Type, a.Name, a.Actions)
}
```

#### 3.Harbor Token 生成分析
MakeToken 方法：/service/token/authutils.go#161
```go
// MakeToken 生成 JWT 字符串
func MakeToken(username, service string, access []*token.ResourceActions) (token string, expiresIn int, issuedAt *time.Time, err error) {
    // 读取用于 JWT 签名的私钥
    pk, err := libtrust.LoadKeyFile(privateKey)
    if err != nil {
        return "", 0, nil, err
    }
    // 生成 Token,expiration 是全局变量, 默认值为 30, 即 Token 过期时间为 30 分钟
    tk, expiresIn, issuedAt, err := makeTokenCore(issuer, username, service, expiration, access, pk)
    if err != nil {
        return "", 0, nil, err
    }
    // 组合 Token, 构成 Header.Claim.Sign 格式的字符串
    rs := fmt.Sprintf("%s.%s", tk.Raw, base64UrlEncode(tk.Signature))
    return rs, expiresIn, issuedAt, nil
}

//makeTokenCore 生成 Token
func makeTokenCore(issuer, subject, audience string, expiration int,
    access []*token.ResourceActions, signingKey libtrust.PrivateKey) (t *token.Token, expiresIn int, issuedAt *time.Time, err error) {
    //JWT 头部
    joseHeader := &token.Header{
        Type:       "JWT",// 类型
        SigningAlg: "RS256",// 签名方法
        KeyID:      signingKey.KeyID(),// 使用私钥生成的唯一 ID
    }
    // 生成一串随机的 JWT ID
    jwtID, err := randString(16)
    if err != nil {
        return nil, 0, nil, fmt.Errorf("Error to generate jwt id: %s", err)
    }

    now := time.Now().UTC()
    issuedAt = &now
    //expiration 为过期时间 (秒)
    expiresIn = expiration * 60
    // 填充 Token 结构
    claimSet := &token.ClaimSet{
        Issuer:     issuer,//Token 签发者
        Subject:    subject,// 获取 Token 的用户
        Audience:   audience,//Token 接收者
        Expiration: now.Add(time.Duration(expiration) * time.Minute).Unix(),//Token 过期时间
        NotBefore:  now.Unix(),
        IssuedAt:   now.Unix(),//Token 签发时间
        JWTID:      jwtID,
        Access:     access,// 权限
    }

    var joseHeaderBytes, claimSetBytes []byte
    // 将 Header 进行 Json 序列化
    if joseHeaderBytes, err = json.Marshal(joseHeader); err != nil {
        return nil, 0, nil, fmt.Errorf("unable to marshal jose header: %s", err)
    }
    // 将 Claim 进行 Json 序列化
    if claimSetBytes, err = json.Marshal(claimSet); err != nil {
        return nil, 0, nil, fmt.Errorf("unable to marshal claim set: %s", err)
    }
    // 将 Header 和 Claim 字节数组进行 base64 编码
    encodedJoseHeader := base64UrlEncode(joseHeaderBytes)
    encodedClaimSet := base64UrlEncode(claimSetBytes)
    // 将 Header 和 Claim 合并为 Header.Claim
    payload := fmt.Sprintf("%s.%s", encodedJoseHeader, encodedClaimSet)

    // 使用私钥对 payload 进行签名
    var signatureBytes []byte
    if signatureBytes, _, err = signingKey.Sign(strings.NewReader(payload), crypto.SHA256); err != nil {
        return nil, 0, nil, fmt.Errorf("unable to sign jwt payload: %s", err)
    }

    signature := base64UrlEncode(signatureBytes)
    // 组合 Token, 构成 Header.Claim.Sign 格式的字符串
    tokenString := fmt.Sprintf("%s.%s", payload, signature)
    // 创建 Token 实例
    t, err = token.NewToken(tokenString)
    return
}
```
