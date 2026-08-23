# Reasoning Proxy

这是一个使用 Node.js 编写的本地 HTTP 反向代理。它把本机收到的 API 请求转发到指定的上游服务，并为没有显式设置 `reasoning_effort` 的 JSON POST 请求自动补充默认值。

它适合用于需要统一设置大模型推理强度的内部服务或 OpenAI 兼容 API 调试场景。

## 运作原理

整体请求链路如下：

```text
大模型客户端
    |
    | HTTP request
    v
127.0.0.1:3120
    |
    | JSON POST 且缺少 reasoning_effort 时，注入 reasoning_effort=high
    v
10.0.8.19:80
    |
    v
上游服务响应
```

程序启动后，`proxy.js` 会执行以下操作：

1. 在 `127.0.0.1:3120` 上监听请求。
2. 读取请求体，并保留原来的请求方法、URL 和请求头。
3. 当请求方法是 `POST`、内容类型包含 `application/json` 且请求体是合法 JSON 时，检查 `reasoning_effort` 字段。
4. 如果字段不存在，就加入默认值 `high`；如果调用方已经设置，则不覆盖调用方的值。
5. 将请求转发到目标主机和端口，并把上游响应原样返回给客户端。
6. 尝试从响应前 2 MB 中提取提示词缓存统计，例如 `cached_tokens`，用于写入日志。

请求体不是合法 JSON 时，代理会直接透传，不会因为改写失败而阻断请求。

## 目录说明

```text
proxy.js       代理主程序
config.bat     配置文件（目标 IP、端口、推理等级）
start.bat      Windows 启动脚本
proxy.log      运行日志，启动后自动追加
proxy.err.log  预留的错误日志文件
```

## 迁移到新电脑

### 1. 安装 Node.js

在新电脑安装 Node.js 的 LTS 版本。安装完成后打开 PowerShell，确认命令可用：

```powershell
node --version
```

本项目只使用 Node.js 内置模块，不需要执行 `npm install`，也没有 `package.json`。

### 2. 复制项目文件

把以下文件复制到新电脑的同一个文件夹中：

```text
proxy.js
start.bat
config.bat
```

日志文件不是必须的；如果一起复制，程序会继续向现有日志追加内容。

### 3. 修改配置并确认网络条件

按需编辑 `config.bat`，确认上游地址和推理等级。新电脑必须能够访问配置的上游服务：

```text
10.0.8.19:80
```

如果目标服务器、端口或网络环境不同，直接修改 `config.bat` 中的 `TARGET_HOST` 和 `TARGET_PORT`。

### 4. 启动代理

双击 `start.bat`，或者在项目目录执行：

```powershell
node .\proxy.js
```

看到类似下面的日志，就表示本地代理已经启动：

```text
[proxy] listening on http://127.0.0.1:3120
[proxy] forwarding to http://10.0.8.19:80
[proxy] default reasoning_effort=high
```

### 5. 修改客户端地址

原本直接访问上游服务的客户端，需要改为访问本地代理地址：

```text
http://127.0.0.1:3120
```

请求路径会被原样转发。例如客户端请求：

```text
POST http://127.0.0.1:3120/v1/chat/completions
```

代理会向上游请求：

```text
POST http://10.0.8.19:80/v1/chat/completions
```

## 配置

推荐方式：直接编辑项目根目录的 `config.bat`，然后重新运行 `start.bat` 即可生效。

```bat
rem 本地监听端口
set PROXY_PORT=3120

rem 上游服务器地址与端口
set TARGET_HOST=10.0.8.19
set TARGET_PORT=80

rem 默认推理强度（low / medium / high）
set REASONING_EFFORT=high
```

也可以不使用配置文件，通过环境变量临时覆盖。

### PowerShell

```powershell
$env:PROXY_PORT = "3120"
$env:TARGET_HOST = "10.0.8.19"
$env:TARGET_PORT = "80"
$env:REASONING_EFFORT = "high"
node .\proxy.js
```

### CMD

```bat
set PROXY_PORT=3120
set TARGET_HOST=10.0.8.19
set TARGET_PORT=80
set REASONING_EFFORT=high
node proxy.js
```

配置项说明：

| 环境变量 | 默认值 | 作用 |
| --- | --- | --- |
| `PROXY_PORT` | `3120` | 本地监听端口 |
| `TARGET_HOST` | `10.0.8.19` | 上游服务器地址 |
| `TARGET_PORT` | `80` | 上游服务器端口 |
| `REASONING_EFFORT` | `high` | 缺少字段时注入的默认推理强度 |

`start.bat` 启动时会自动加载 `config.bat`，端口占用检查和启动提示都会跟随配置的端口。如果配置文件不存在，程序会使用上表中的内置默认值。

## 简单验证

代理启动后，可以用 PowerShell 发送一个测试请求：

```powershell
$body = @{ model = "test-model"; messages = @() } | ConvertTo-Json
Invoke-WebRequest `
  -Uri "http://127.0.0.1:3120/test" `
  -Method POST `
  -ContentType "application/json" `
  -Body $body
```

如果请求到达代理日志，应能看到类似：

```text
[proxy] injected reasoning_effort=high for model=test-model
```

这个测试是否能得到正常响应，取决于 `10.0.8.19:80` 上是否存在对应服务和路径。

## 常见问题

### 出现 `502 Bad Gateway`

说明代理无法连接上游服务。检查：

- 新电脑是否连接了正确的内网或 VPN。
- `TARGET_HOST` 和 `TARGET_PORT` 是否正确。
- 上游服务是否正在运行。
- 防火墙是否阻止了连接。

### 提示端口已被占用

`3120` 已经被其他程序使用，或者已有一个代理实例运行。可以查看占用进程：

```powershell
Get-NetTCPConnection -LocalPort 3120 -State Listen
```

关闭已有实例后再启动，或者手动使用其他端口启动代理。

### `reasoning_effort` 没有生效

检查请求是否同时满足以下条件：

- 方法是 `POST`。
- `Content-Type` 包含 `application/json`。
- 请求体是合法 JSON。
- 请求体中没有已经存在的 `reasoning_effort` 字段。

如果调用方已经设置该字段，代理会保留调用方的值。

## 安全注意事项

- 代理只监听 `127.0.0.1`，默认不会直接暴露给局域网其他机器。
- 它没有身份验证，能访问本机端口的程序都可以通过它发送请求。
- 代理会记录模型名、请求大小、请求摘要哈希和部分缓存统计，不会主动记录完整请求体。
- 不要把监听地址随意改成 `0.0.0.0`，除非已经配置访问控制、防火墙和身份验证。
- 如果上游使用 HTTPS，目前代码需要额外改造，不能仅通过设置 `TARGET_PORT=443` 就自动变成 HTTPS 代理。

## 停止服务

在运行代理的窗口按 `Ctrl+C` 即可停止。