@echo off
cd /d "%~dp0"
rem 加载配置文件（目标 IP、端口、推理等级等）
if exist "%~dp0config.bat" call "%~dp0config.bat"
netstat -ano | findstr /R /C:":%PROXY_PORT% *.*LISTENING" >nul 2>&1
if %errorlevel%==0 (
    echo [proxy] Port %PROXY_PORT% is already in use, proxy seems to be running.
    echo [proxy] Close the other instance first if you want to restart it.
    pause
    exit /b 0
)
echo [proxy] Starting reasoning proxy on http://127.0.0.1:%PROXY_PORT% ...
echo [proxy] Target: %TARGET_HOST%:%TARGET_PORT%, reasoning_effort=%REASONING_EFFORT%, kimi_temperature=%KIMI_TEMPERATURE%
powershell -NoProfile -Command "node '%~dp0proxy.js' 2>&1 | Tee-Object -FilePath '%~dp0proxy.log' -Append"
echo.
echo [proxy] Exited unexpectedly. Check the error above.
pause
