@echo off
cd /d "%~dp0"
rem load config (target ip, port, reasoning effort, kimi params)
if exist "%~dp0..\config\config.bat" call "%~dp0..\config\config.bat"
netstat -ano | findstr /R /C:":%PROXY_PORT% *.*LISTENING" >nul 2>&1
if %errorlevel%==0 (
    echo [proxy] Port %PROXY_PORT% is already in use, proxy seems to be running.
    echo [proxy] Close the other instance first if you want to restart it.
    pause
    exit /b 0
)
echo [proxy] Starting reasoning proxy in background on http://127.0.0.1:%PROXY_PORT% ...
echo [proxy] Target: %TARGET_HOST%:%TARGET_PORT%, reasoning_effort=%REASONING_EFFORT%, kimi_temperature=%KIMI_TEMPERATURE%, kimi_top_p=%KIMI_TOP_P%
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-background.ps1" -ProxyPath "%~dp0proxy.js" -ProxyExe "%REASONING_PROXY_EXE%" -WorkingDirectory "%CD%" -LogPath "%~dp0..\logs\proxy.log" -ErrLogPath "%~dp0..\logs\proxy.err.log"
echo [proxy] Started in background. This window can be closed.
ping 127.0.0.1 -n 4 >nul
exit /b 0
