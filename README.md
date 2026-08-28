# Reasoning Proxy

Reasoning Proxy 是一个本地 HTTP 反向代理，附带一个 WPF 图形界面。它会接收本机 API 请求并转发到上游服务，自动补充 `reasoning_effort`，并把 Kimi 模型的 `temperature`、`top_p` 修正为配置值。

项目支持两种运行方式：

- 源码模式：需要安装 Node.js，直接运行 `scripts\proxy.js` 或图形界面。
- 打包模式：生成单个 `ReasoningProxy.exe`，目标电脑不需要安装 Node.js。

## 功能

- 监听 `127.0.0.1:3120`，把请求原样转发到上游地址。
- 对 JSON POST 请求自动注入缺失的 `reasoning_effort`。
- 模型名包含 `kimi` 时，把 `temperature` 和 `top_p` 改写为配置值。
- 提供图形界面，可查看运行状态、切换推理等级、查看日志，并常驻系统托盘。
- 支持打包为单文件 exe，内置 Node.js 运行时、代理脚本、GUI 脚本、图标和默认配置。

## 快速开始

### 方式一：使用打包版 exe

如果已经执行过打包，直接双击：

```text
dist\ReasoningProxy.exe
```

首次运行会在 exe 同目录生成 `config\config.bat` 和 `logs\`。如果 exe 所在目录不可写，会自动改用 `%LOCALAPPDATA%\ReasoningProxy\data\`。

### 方式二：源码运行

先确认已安装 Node.js：

```powershell
node --version
```

然后在项目根目录执行：

```powershell
node .\scripts\proxy.js
```

也可以双击 `scripts\gui.vbs` 打开图形界面。项目只使用 Node.js 内置模块，不需要执行 `npm install`。

## 目录结构

```text
reasoning-proxy/
├─ README.md                 项目说明
├─ sea-config.json           Node SEA 打包配置
├─ config/
│  └─ config.bat             端口、上游地址、推理等级、Kimi 参数
├─ scripts/
│  ├─ build-exe.ps1          打包 exe 的构建脚本
│  ├─ set-exe-icon.mjs       给 exe 写入 logo 图标
│  ├─ proxy.js               代理主程序
│  ├─ proxy-gui.ps1          WPF 图形界面
│  ├─ start.bat              源码模式后台启动代理
│  ├─ start-background.ps1   后台启动辅助脚本
│  ├─ stop.bat               按端口停止代理
│  ├─ gui.vbs                隐藏启动 GUI 的辅助脚本
│  └─ create-shortcut.ps1    重新生成源码模式快捷方式
├─ assets/
│  ├─ logo.png               GUI 窗口图标
│  └─ logo.ico               exe、托盘、快捷方式图标
├─ build/
│  └─ sea-entry.js           exe 内嵌入口，分发 GUI / 代理模式
├─ dist/                     打包输出目录，执行构建后生成
└─ logs/                     运行日志目录，自动生成
```

其中 `dist\ReasoningProxy.exe` 是最终交付文件，`build\resedit` 这类图标工具依赖不会保留在项目里，会放到系统临时目录。

## 运作原理

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

`scripts\proxy.js` 的处理过程：

1. 在 `127.0.0.1:3120` 监听请求。
2. 保留原始请求方法、URL 和请求头。
3. 当请求是 `POST`、内容类型包含 `application/json` 且请求体是合法 JSON 时，检查 `reasoning_effort` 字段。
4. 如果字段缺失，从 `config\config.bat` 读取 `REASONING_EFFORT` 并注入；如果调用方已设置，则不覆盖。
5. 模型名包含 `kimi` 时，把非配置值的 `temperature`、`top_p` 改写为 `KIMI_TEMPERATURE` 和 `KIMI_TOP_P`。
6. 把请求转发到目标主机和端口，并把上游响应原样返回。
7. 尝试从响应前 2 MB 提取缓存统计，例如 `cached_tokens`，写入日志。

请求体不是合法 JSON 时，代理会直接透传，不会因为改写失败阻断请求。

## 打包为 exe

打包需要本机已安装 Node.js，并首次访问网络以下载 `postject` 和 `resedit`。

在项目根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-exe.ps1
```

打包成功后生成：

```text
dist\ReasoningProxy.exe
```

打包会自动完成：

- 使用 Node SEA 生成单文件可执行程序。
- 内置 Node.js 运行时、代理脚本、图形界面脚本、图标和默认配置。
- 把 `assets\logo.ico` 写入 exe 文件图标。
- 清理中间文件，不在项目目录留下临时依赖。

打包版使用方式：

- 双击 `ReasoningProxy.exe`：打开图形界面。
- 执行 `ReasoningProxy.exe --proxy`：后台代理模式。
- 打包版第一次启动可能出现一次黑色控制台闪烁，这是 Node SEA 控制台程序的限制；代理进程本身可以隐藏窗口运行。
- 打包前请关闭正在运行的 `ReasoningProxy.exe`，否则旧的 `dist` 目录可能被占用。

## 配置

源码模式读取项目根目录的 `config\config.bat`。打包模式首次运行会自动生成同款配置文件。

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

配置项说明：

| 环境变量 | 默认值 | 作用 |
| --- | --- | --- |
| `PROXY_PORT` | `3120` | 本地监听端口 |
| `TARGET_HOST` | `10.0.8.19` | 上游服务器地址 |
| `TARGET_PORT` | `80` | 上游服务器端口 |
| `REASONING_EFFORT` | `high` | 缺失字段时注入的默认推理强度（`low` / `medium` / `high` / `max`） |
| `KIMI_TEMPERATURE` | `1` | Kimi 模型请求中的固定 `temperature` 值 |
| `KIMI_TOP_P` | `0.95` | Kimi 模型请求中的固定 `top_p` 值 |

也可以不使用配置文件，通过环境变量临时覆盖：

```powershell
$env:PROXY_PORT = "3120"
$env:TARGET_HOST = "10.0.8.19"
$env:TARGET_PORT = "80"
$env:REASONING_EFFORT = "high"
$env:KIMI_TEMPERATURE = "1"
$env:KIMI_TOP_P = "0.95"
node .\scripts\proxy.js
```

`REASONING_EFFORT` 会在每次请求时重新读取，因此切换推理等级不需要重启代理。端口、目标地址和 Kimi 参数修改后需要重启代理。

## 图形界面

源码模式可以双击 `scripts\gui.vbs` 启动 GUI，或运行 `scripts\create-shortcut.ps1` 重新生成快捷方式。打包模式直接双击 `ReasoningProxy.exe`。

界面提供以下功能：

- 显示代理运行状态、进程 PID、本地地址、目标地址和 Kimi 参数。
- 推理等级支持 `low` / `medium` / `high` / `max` 四档，点击后直接写入配置，下一次请求立即生效。
- 点击“查看日志”可以在状态面板和日志面板之间切换，日志默认滚动到最新内容。
- 关闭窗口不会停止代理，界面会隐藏到系统托盘；双击托盘图标可重新打开，右键托盘可退出界面。

## 简单验证

代理启动后，发送一个测试请求：

```powershell
$body = @{ model = "test-model"; messages = @() } | ConvertTo-Json
Invoke-WebRequest `
  -Uri "http://127.0.0.1:3120/test" `
  -Method POST `
  -ContentType "application/json" `
  -Body $body
```

如果请求到达代理日志，应能看到：

```text
[proxy] injected reasoning_effort=high for model=test-model
```

测试请求是否能得到正常响应，取决于上游 `10.0.8.19:80` 是否存在对应服务和路径。

## 部署到其他电脑

### 推荐：只复制 exe

把打包后的文件复制到目标电脑：

```text
dist\ReasoningProxy.exe
```

目标电脑不需要安装 Node.js。首次运行后，exe 同目录会自动生成 `config\config.bat` 和 `logs\`。

### 源码模式：复制项目

如果目标电脑已经安装 Node.js，可以复制以下文件：

```text
scripts\proxy.js
scripts\proxy-gui.ps1
scripts\gui.vbs
scripts\create-shortcut.ps1
scripts\start-background.ps1
scripts\start.bat
scripts\stop.bat
config\config.bat
assets\logo.png
assets\logo.ico
```

`logs` 目录不是必需的；如果一起复制，程序会继续向现有日志追加内容。

## 常见问题

### 出现 `502 Bad Gateway`

说明代理无法连接上游服务。检查：

- 是否连接了正确的内网或 VPN。
- `TARGET_HOST` 和 `TARGET_PORT` 是否正确。
- 上游服务是否正在运行。
- 防火墙是否阻止了连接。

### 提示端口已被占用

`3120` 已被其他程序使用，或已有一个代理实例运行。查看占用进程：

```powershell
Get-NetTCPConnection -LocalPort 3120 -State Listen
```

关闭已有实例后再启动，或改用其他端口。

### `reasoning_effort` 没有生效

检查请求是否同时满足：

- 方法是 `POST`。
- `Content-Type` 包含 `application/json`。
- 请求体是合法 JSON。
- 请求体中没有已经存在的 `reasoning_effort` 字段。

如果调用方已经设置该字段，代理会保留调用方的值。

### 使用 Kimi 模型时提示 `invalid temperature` 或 `invalid top_p`

Kimi 推理模型默认只接受 `temperature=1` 和 `top_p=0.95`，可以通过 `KIMI_TEMPERATURE`、`KIMI_TOP_P` 调整。代理会在模型名包含 `kimi` 时，把非配置值的 `temperature`、`top_p` 自动改写后再转发。

### 使用 Kimi 模型时提示 `invalid reasoning_effort`

Kimi K3 官方文档只接受 `low` / `high` / `max` 三档。图形界面里的 `medium` 是为兼容更多客户端和模型预留的档位；如果上游返回 `invalid reasoning_effort`，切回 `low`、`high` 或 `max` 即可。

## 安全注意事项

- 代理默认只监听 `127.0.0.1`，不会直接暴露给局域网其他机器。
- 代理没有身份验证，能访问本机端口的程序都可以通过它发送请求。
- 代理会记录模型名、请求大小、请求摘要哈希和部分缓存统计，不会主动记录完整请求体。
- 不要随意把监听地址改成 `0.0.0.0`，除非已经配置访问控制、防火墙和身份验证。
- 如果上游使用 HTTPS，需要额外改造代码，不能仅通过设置 `TARGET_PORT=443` 自动变成 HTTPS 代理。

## 停止服务

后台运行时没有可直接关闭的窗口。可以双击 `scripts\stop.bat`，也可以在图形界面中点击“停止代理”。

手动停止：

```powershell
Get-NetTCPConnection -LocalPort 3120 -State Listen |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
```

修改 `PROXY_PORT`、`TARGET_HOST`、`TARGET_PORT`、`KIMI_TEMPERATURE`、`KIMI_TOP_P` 后需要重启代理。推理等级不需要重启，修改后下一次请求立即生效。
