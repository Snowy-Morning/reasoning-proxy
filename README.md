# Reasoning Proxy

这是一个使用 Node.js 编写的本地 HTTP 反向代理。它把本机收到的 API 请求转发到指定的上游服务，并为没有显式设置 `reasoning_effort` 的 JSON POST 请求自动补充默认值，同时把 Kimi 模型的 `temperature` 和 `top_p` 修正为 `KIMI_TEMPERATURE`、`KIMI_TOP_P` 配置值。

它适合用于需要统一设置大模型推理强度的内部服务或 OpenAI 兼容 API 调试场景。

项目还附带一个 WPF 图形界面（`gui.vbs` / `scripts\proxy-gui.ps1`），可以查看运行状态、切换推理等级、查看日志，并常驻系统托盘。

## 运作原理

整体请求链路如下：

```text
大模型客户端
    |
    | HTTP request
    v
127.0.0.1:3120
    |
    | JSON POST 时注入 reasoning_effort；模型名含 kimi 时修正 temperature/top_p
    v
10.0.8.19:80
    |
    v
上游服务响应
```

程序启动后，`scripts\proxy.js` 会执行以下操作：

1. 在 `127.0.0.1:3120` 上监听请求。
2. 读取请求体，并保留原来的请求方法、URL 和请求头。
3. 当请求方法是 `POST`、内容类型包含 `application/json` 且请求体是合法 JSON 时，检查 `reasoning_effort` 字段。
4. 如果字段不存在，就从 `config\config.bat` 读取 `REASONING_EFFORT` 并注入（默认 `high`）；如果调用方已经设置，则不覆盖调用方的值。
5. 当模型名包含 `kimi` 时，把非配置值的 `temperature`、`top_p` 改写为 `KIMI_TEMPERATURE`（默认 `1`）和 `KIMI_TOP_P`（默认 `0.95`）。
6. 将请求转发到目标主机和端口，并把上游响应原样返回给客户端。
7. 尝试从响应前 2 MB 中提取提示词缓存统计，例如 `cached_tokens`，用于写入日志。

请求体不是合法 JSON 时，代理会直接透传，不会因为改写失败而阻断请求。

## 目录说明

```text
start.bat      启动代理（根目录入口）
stop.bat       停止代理（根目录入口）
gui.vbs        打开图形界面（根目录入口）
scripts/       实现代码（proxy.js、proxy-gui.ps1、start.bat、stop.bat 等）
config/        配置文件（config.bat）
assets/        图标资源（logo.png / logo.ico）
logs/          运行日志（proxy.log / proxy.err.log）
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
start.bat
stop.bat
gui.vbs
scripts\proxy.js
scripts\proxy-gui.ps1
scripts\start-background.ps1
scripts\start.bat
scripts\stop.bat
config\config.bat
assets\logo.png
assets\logo.ico
```

`logs` 目录不是必须的；如果一起复制，程序会继续向现有日志追加内容。

### 3. 修改配置并确认网络条件

按需编辑 `config\config.bat`，确认上游地址和推理等级。新电脑必须能够访问配置的上游服务：

```text
10.0.8.19:80
```

如果目标服务器、端口或网络环境不同，直接修改 `config\config.bat` 中的 `TARGET_HOST` 和 `TARGET_PORT`。

### 4. 启动代理

双击 `gui.vbs` 可以打开深色图形界面，不会弹出 cmd 窗口，窗口和托盘均使用 `logo` 图标。图形界面是单实例的，重复打开只会激活已有窗口；即使界面隐藏到托盘，重复启动也会把已有窗口重新唤起。

界面提供以下功能：

- 显示代理运行状态、进程 PID、本地/目标地址和 Kimi 参数。
- 推理等级支持 `low` / `medium` / `high` / `max` 四档，点击后直接写入 `config\config.bat`，下一次请求立即生效，无需重启代理，当前档位以绿色高亮。
- 点击“查看日志”可以在状态面板和日志面板之间切换，日志默认滚动到最新内容。
- 关闭窗口不会停止代理，界面会隐藏到系统托盘；双击托盘图标可重新打开，右键托盘可选择退出界面（不停止代理）。

也可以双击 `start.bat` 直接后台启动，不打开界面。代理会在后台运行，启动窗口几秒后会自动关闭。需要停止时双击 `stop.bat` 即可。

如果需要在前台调试，也可以在项目目录执行：

```powershell
node .\scripts\proxy.js
```

后台启动后，`logs\proxy.log` 中会出现类似下面的内容，表示本地代理已经启动：

```text
[proxy] listening on http://127.0.0.1:3120
[proxy] forwarding to http://10.0.8.19:80
[proxy] default reasoning_effort=high
[proxy] default kimi temperature=1
[proxy] default kimi top_p=0.95
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

推荐方式：直接编辑项目根目录的 `config\config.bat` 即可生效，推理等级会在下一次请求时自动读取，无需重启。

```bat
rem local listening port
set PROXY_PORT=3120

rem upstream server address and port
set TARGET_HOST=10.0.8.19
set TARGET_PORT=80

rem default reasoning effort (low / medium / high / max)
set REASONING_EFFORT=high

rem kimi reasoning models accept temperature=1 and top_p=0.95 by default
set KIMI_TEMPERATURE=1

rem you can adjust these values if your upstream accepts others
set KIMI_TOP_P=0.95
```

也可以不使用配置文件，通过环境变量临时覆盖。

### PowerShell

```powershell
$env:PROXY_PORT = "3120"
$env:TARGET_HOST = "10.0.8.19"
$env:TARGET_PORT = "80"
$env:REASONING_EFFORT = "high"
$env:KIMI_TEMPERATURE = "1"
$env:KIMI_TOP_P = "0.95"
node .\scripts\proxy.js
```

### CMD

```bat
set PROXY_PORT=3120
set TARGET_HOST=10.0.8.19
set TARGET_PORT=80
set REASONING_EFFORT=high
set KIMI_TEMPERATURE=1
set KIMI_TOP_P=0.95
node scripts\proxy.js
```

配置项说明：

| 环境变量 | 默认值 | 作用 |
| --- | --- | --- |
| `PROXY_PORT` | `3120` | 本地监听端口 |
| `TARGET_HOST` | `10.0.8.19` | 上游服务器地址 |
| `TARGET_PORT` | `80` | 上游服务器端口 |
| `REASONING_EFFORT` | `high` | 缺少字段时注入的默认推理强度（`low` / `medium` / `high` / `max`） |
| `KIMI_TEMPERATURE` | `1` | Kimi 模型请求中的固定 `temperature` 值 |
| `KIMI_TOP_P` | `0.95` | Kimi 模型请求中的固定 `top_p` 值 |

`start.bat` 启动时会自动加载 `config\config.bat`，端口占用检查和启动提示都会跟随配置的端口。代理启动后会在后台运行，日志追加到 `logs\proxy.log` 和 `logs\proxy.err.log`。如果配置文件不存在，程序会使用上表中的内置默认值。`REASONING_EFFORT` 由代理在每次请求时重新读取，因此图形界面里切换推理等级不需要重启代理；端口、目标地址和 Kimi 参数仍需要在启动前配置好。

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

### 使用 Kimi 模型时提示 `invalid temperature` 或 `invalid top_p`

Kimi 的推理模型默认只接受 `temperature=1` 和 `top_p=0.95`（可通过 `KIMI_TEMPERATURE`、`KIMI_TOP_P` 调整），而 VS Code Copilot 等客户端可能会发送其他值。代理现在会在请求中包含 `kimi` 模型名时，把非配置值的 `temperature`、`top_p` 自动改写为 `KIMI_TEMPERATURE`（默认 `1`）和 `KIMI_TOP_P`（默认 `0.95`）再转发；如果请求没有携带对应字段，则保持原样。

### 使用 Kimi 模型时提示 `invalid reasoning_effort`

Kimi K3 官方文档只接受 `low` / `high` / `max` 三档。图形界面里的 `medium` 是为兼容更多客户端/模型预留的档位；如果上游返回 `invalid reasoning_effort`，把推理等级切回 `low`、`high` 或 `max` 即可，切换后下一次请求立即生效。

## 安全注意事项

- 代理只监听 `127.0.0.1`，默认不会直接暴露给局域网其他机器。
- 它没有身份验证，能访问本机端口的程序都可以通过它发送请求。
- 代理会记录模型名、请求大小、请求摘要哈希和部分缓存统计，不会主动记录完整请求体。
- 不要把监听地址随意改成 `0.0.0.0`，除非已经配置访问控制、防火墙和身份验证。
- 如果上游使用 HTTPS，目前代码需要额外改造，不能仅通过设置 `TARGET_PORT=443` 就自动变成 HTTPS 代理。

## 停止服务

后台运行时没有可直接关闭的窗口，双击 `stop.bat` 会按配置的端口找到代理进程并结束，也可以在图形界面中点击“停止代理”。

也可以手动执行：

```powershell
Get-NetTCPConnection -LocalPort 3120 -State Listen |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
```

修改 `PROXY_PORT`、`TARGET_HOST`、`TARGET_PORT`、`KIMI_TEMPERATURE`、`KIMI_TOP_P` 后需要重启代理：先按上面的方法停止旧实例，再双击 `start.bat`。推理等级不需要重启，在图形界面切换或编辑 `config\config.bat` 后下一次请求就会生效。
