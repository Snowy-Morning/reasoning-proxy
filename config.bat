@echo off
rem ===== reasoning-proxy 配置文件 =====
rem 修改下面的值后重新运行 start.bat 即可生效

rem 本地监听端口
set PROXY_PORT=3120

rem 上游服务器地址与端口
set TARGET_HOST=10.0.8.19
set TARGET_PORT=80

rem 默认推理强度（low / medium / high）
set REASONING_EFFORT=high
