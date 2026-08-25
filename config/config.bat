@echo off
rem ===== reasoning-proxy config =====
rem Edit values below, then run start.bat again.

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
