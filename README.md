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
- 一键把上游模型列表同步进 VS Code 的 `chatLanguageModels.json`，同步前可以在表格里逐个勾选模型、改上下文窗口和图片处理，勾选结果就是最终列表。
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

默认版本号为 `1.2.2`。需要自定义版本时传入 `-Version`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-exe.ps1 -Version "1.0.1"
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
- 执行 `ReasoningProxy.exe --uninstall`：清理本工具生成的运行文件，见「卸载」。
- 打包版启动时会把自己登记到 Windows 的「设置 → 应用」里，在那里能看到「Reasoning Proxy」和它的卸载按钮；不想用命令行时从那里卸。
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

### 同步上游模型到 VS Code

点击“同步上游模型到 VS Code”（系统托盘右键菜单里也有同名项），会先拉取上游 `/v1/models`，然后弹出一个选择窗口。这个工具只针对 VS Code，写入目标固定是 `%APPDATA%\Code\User\chatLanguageModels.json`，路径显示在窗口标题下面。

- 窗口是一张表格，列为 `模型名称` / `上下文窗口` / `图片处理方式`，支持搜索和全选、全不选、只勾新增。`只勾新增` 会取消勾选已配置的那些，也就是把它们一并删掉，底部会先显示“移除几个”再让你确认。
- 已经配置过的模型置顶并默认勾选，`上下文窗口` 那格的水印写的就是文件里现在的值，`图片处理方式` 下拉也是当前值。不改它就等于不动它：同步时这条会被原样写回，连格式都不变。改了哪个单元格，就地更新那一条的 `maxInputTokens` 或 `vision`，其余字段保留。
- 上游已经不再返回、但文件里还留着的模型会单独列一行，标记为 `仅本地`，同样默认勾选；不想留就取消勾选。
- `上下文窗口` 一格永远是空的，水印写的是这格留空时会用的值。已配置的模型用文件里的值；只有文件里还没有的模型才走默认，先看 `LM_MODEL_CONTEXT` 命中的那一族，再退到 `LM_MAX_INPUT_TOKENS`（默认 `1M`）。想单独指定就直接填，接受 `1M`、`200K`、`1000000` 三种写法。
- `图片处理方式` 下拉选择 `原样发送图片`（`vision: true`）或 `不发送图片`（`vision: false`）。
- 底部实时显示“新增 · 更新 · 移除 · 保持 · 跳过”各几个，确认后再点“同步”。

上游的 `/v1/models` 只返回 `id` / `type` / `display_name` / `created_at`，没有任何上下文长度或能力字段，`/v1/models/<id>` 也是 404，所以上下文窗口无法自动获取。想让它按模型族各走各的默认值，用 `LM_MODEL_CONTEXT` 配一次：

```bat
set LM_MODEL_CONTEXT=claude=1M,gpt-6=1M,gpt=200K,kimi=256K
```

按子串匹配，写在前面的优先，命中就用它，没命中的走 `LM_MAX_INPUT_TOKENS`。自动同步（`LM_AUTOSYNC=1`）同样吃这份配置。

勾选的列表就是最终状态：点“同步”后，本代理那一组 provider 里没被勾选的模型会被删除，勾了的会按需新增或就地改字段，完全没动过的条目即使勾选也不会被重写，所以不会产生多余的备份。删除只发生在本代理自己的那一组里，别的 provider 一律不碰；如果界面识别不出哪一组属于本代理，就退化成只新增不删除。一个都没勾时直接拒绝执行，避免误清空。上游已经消失但仍被勾选的模型照常保留。每次真正写入前都会先生成 `chatLanguageModels.json.bak-时间戳` 备份，备份放在本工具自己的目录而不是 VS Code 的用户目录，见 `LM_BACKUP_DIR`；早先版本留在编辑器目录里的那些备份会在下一次真正写入时搬过去，名字对不上的文件一律不碰。备份不在 exe 旁边，某一次同步具体写到了哪里，看 `logs\lm-sync.log`，每个目标一行，字段 `Backup` 就是路径。

自动同步（`LM_AUTOSYNC=1`）走的是另一套规则：它没有人帮忙确认，所以只追加、不删除，上游偶尔抽风也不会把已有配置清空。

改完后在 VS Code 里执行一次“开发人员: 重新加载窗口”即可看到新模型。

密钥不需要手动填写，按以下顺序自动获取：

1. 复用代理正在替 VS Code 转发的 `Authorization` 头（代理进程内内存转发，不落盘）。
2. `config\config.bat` 里的 `LM_API_KEY`。
3. `~\.codex\auth.json` 里的 `OPENAI_API_KEY`，仅当 `~\.codex\config.toml` 的 `base_url` 指向同一个上游主机时才使用。
4. 环境变量 `LM_API_KEY` / `OPENAI_API_KEY`。

四条都拿不到时才会弹窗询问。密钥只用于那一次 `GET /v1/models`，不会被写进任何文件；`chatLanguageModels.json` 里保存的仍是 VS Code 自己的 `${input:chat.lm.secret.*}` 引用。

代理额外提供两个仅监听 `127.0.0.1` 的内部路由，供界面查询状态和借用请求头，不会转发到上游：`GET /__reasoning_proxy/status` 和 `GET /__reasoning_proxy/models`。

`config\config.bat` 中的可调项：

| 键 | 作用 | 默认值 |
| --- | --- | --- |
| `LM_CONFIG_PATH` | 指定要写入的 `chatLanguageModels.json`，留空则用 VS Code stable 的路径 | 空 |
| `LM_MODEL_URL` | 写进每个模型条目的地址 | `http://127.0.0.1:PROXY_PORT/v1` |
| `LM_PROVIDER_NAME` | 新建 provider 块时使用的名字 | `Reasoning Proxy` |
| `LM_MAX_INPUT_TOKENS` / `LM_MAX_OUTPUT_TOKENS` | 新增模型的默认上下文与输出上限 | `1000000` / `128000` |
| `LM_TOOL_CALLING` / `LM_VISION` | 新增模型默认是否开启工具调用与视觉 | `1` / `1` |
| `LM_MODEL_CONTEXT` | 按模型族预填表格里的上下文窗口，首个命中的子串生效 | 空 |
| `LM_SKIP_MODELS` | 模型 id 命中这些子串时在选择窗口里标为 `已过滤`，不可勾选 | `embedding,rerank,...` |
| `LM_INCLUDE_MODELS` | 非空时只有命中这些子串的模型可勾选 | 空 |
| `LM_BACKUP_KEEP` | 每个目标文件保留多少个 `chatLanguageModels.json.bak-*`，真正写入之后回收超出的部分；设为 `0` 或负数则全部保留 | `10` |
| `LM_BACKUP_DIR` | 上述备份的根目录，每个目标文件在里面占一个子文件夹。留空用 `%LOCALAPPDATA%\ReasoningProxy\backups`，该目录会随 `--uninstall` 一起删除 | 空 |
| `LM_API_KEY` | 直连上游时使用的密钥 | 空 |
| `LM_AUTOSYNC` | 设为 `1` 时，代理捕获到 VS Code 请求后自动同步一次，不弹选择窗口 | `0` |

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

## 卸载

打包版每次启动会把自己写进 `HKEY_CURRENT_USER` 的卸载登记表，所以在「设置 → 应用 → 安装的应用」里能看到 **Reasoning Proxy** 和一个「卸载」按钮，点它就是执行下面这条命令。

也可以直接执行 `ReasoningProxy.exe --uninstall`，它会：

1. 结束仍在运行的本工具进程（图形界面和后台代理）。只匹配本程序的 exe 路径与它自己的数据目录，从源码目录里起的代理不会被波及。
2. 从「设置 → 应用」的卸载登记表里删掉自己，列表里不会再留下点不动的条目。
3. 删除 `%LOCALAPPDATA%\ReasoningProxy`，包含按版本生成的 `runtime` 目录、备用 `data` 目录，以及同步模型配置时产生的 `backups` 备份。
4. 删除 exe 旁边属于 portable 用法的 `logs\` 和 `config\`。这两处只在里面确实有本工具的东西时才动手：`logs\` 里要有它写过的日志名，`config\config.bat` 里要有它的 `LM_*` 配置项。单纯重名的目录不会被碰。
5. 清掉目标配置文件旁边的遗留备份，也就是备份搬家之前直接写在 VS Code 用户目录里的那些。这里的判定收得很紧：文件名必须是 `<目标文件名>.bak-yyyymmdd-HHMMSS` 这个完整格式，`chatLanguageModels.json.bak-legacy`、`settings.json.bak-20260101-000000` 这类都对不上，不会被误删。
6. 打印处理结果，并提示你手动删除 `ReasoningProxy.exe`。进程无法删除正在运行的自己，这一步留给你。

VS Code 的 `chatLanguageModels.json` 不会被修改或删除，因为里面可能有你自己手工添加的其他 provider。备份默认在 `%LOCALAPPDATA%\ReasoningProxy\backups`，属于第 3 步，所以会被一并清掉；想留下它们就加 `--keep-backups`，那样只删 `runtime` 和 `data`，第 5 步的遗留备份也会原样留着并报告有几个。无论哪种，命令都会打印删除前最近一个备份的路径，方便你在反悔时找回内容。如果你把 `LM_BACKUP_DIR` 指到了别处，卸载不会去动那个目录，只会把路径打印出来让你自己决定。

想找回某次同步之前的配置，到 `<备份目录>\<编辑器目录名>-<路径摘要>\` 里按文件名里的时间戳挑一个，把内容复制回 `chatLanguageModels.json` 即可。

源码模式不需要卸载，删除项目目录就行。
