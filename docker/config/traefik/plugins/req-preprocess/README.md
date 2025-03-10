## preprocess-middleware

为 [Traefik](https://traefik.io/traefik/) 网关开发的一个请求预处理中间件插件，主要用于集中认证。不过与其它的集中认证插件不同的是该插件不会决定请求是否有权到达后面的实际业务逻辑层，只会将其携带的凭证解析成有效负载，如果凭证无效则为空，然后将裁决权交给后续的逻辑层。

### 功能

- 处理会话信息：如果 cookie 中包含会话ID（字段为 `sid`），则会将会话ID转发给认证服务获取对应的身份信息，然后传递给业务逻辑层。

- 解析 JWT 凭证：如果 `header` 中包含字段 `Authorization`，且符合 [`Bearer <token>`](https://swagger.io/docs/specification/authentication/bearer-authentication/) 格式 ，则会对其进行 JWT 解码，然后传递给业务逻辑层。

- 根据特定的Cookie记录重定向。解决 [SwanHubX/habitat#121](https://github.com/SwanHubX/habitat/issues/121)

上述功能都不会干预响应，而是将解析的身份信息放置在请求头 `payload` 上，然后逻辑层根据请求头是否含有 `payload` 参数来判断请求是否携带有效凭证。

### 使用

> 主要介绍在本地开发模式下的使用，参考自：[middleware demo plugin](https://github.com/traefik/plugindemo)

如果在docker中启动Traefik，我们需要将插件放在 `/plugins-local` 目录下，例如：

```yaml
version: '3'

services:
  reverse-proxy:
    image: traefik
    ports:
      - "8090:80"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./conf:/etc/traefik
      - ./plugins/req-preprocess:/plugins-local/src/github.com/SwanHubX/req-preprocess
```

> 插件的路径为 `.traefik.yml` 文件中的 `import` 字段定义，为 `github.com/SwanHubX/req-preprocess`

在 Traefik 配置中引入插件：

```yaml
experimental:
  localPlugins:
    rpp:
      moduleName: github.com/SwanHubX/req-preprocess
```

在中间件中使用插件：

```yaml
http:
  routers:
    to-whoami:
      rule: "PathPrefix(`/api`)"
      service: whoami
      middlewares:
        - "preprocess"
  services:
    whoami:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:3000/"
  middlewares:
    preprocess:
      plugin: 
        rpp:
          AuthUrl: "http://host.docker.internal:3000/api/auth"
          Key: |
          	-----BEGIN PUBLIC KEY-----
            MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA61/d80yCyzy70PtWcslU
            ezWOu02Q6GbtUesCD6mnSiBeocbQGdXejvLRbSrwA8DXyRX8fvg5TPUCFCUza8DW
            J995UhsyIjg6w9ubNA7LbddUDLfREs7pBP7lcjU0LG17LAm9vdusgF6wb7UgGctA
            201uiJ+NilHgf94QaSqtwjaAw6maIdACllxUMj4ZW/4lfJc6pm8YDyOVM5+eE+jE
            yiPoLhkMuROvY9SONe0oMZRnj2O2fwjEPzwXMaWnTF7Em2cJaysgnnDA4dcxa64a
            b1imJPMYq+AAulbAdIiz6YZoUNT12M/zgBgBJcsur4Ss5xFceJMB1N12cjfqA+S3
            7QIDAQAB
            -----END PUBLIC KEY-----

```

### 配置

- `AuthUrl`（可选）：转发的认证接口
- `Key`（可选）：RSA公钥
- `Mark`（可选）：特定的标识。例如Mark设置为 `ht-`，Cookie中有一个Key为 `ht-iop`，那么重定向时将添加路径前缀 `/iop`
