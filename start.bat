@echo off
cd /d "%~dp0"
netstat -ano | findstr /R /C:":3120 *.*LISTENING" >nul 2>&1
if %errorlevel%==0 (
    echo [proxy] Port 3120 is already in use, proxy seems to be running.
    echo [proxy] Close the other instance first if you want to restart it.
    pause
    exit /b 0
)
echo [proxy] Starting reasoning proxy on http://127.0.0.1:3120 ...
powershell -NoProfile -Command "node '%~dp0proxy.js' 2>&1 | Tee-Object -FilePath '%~dp0proxy.log' -Append"
echo.
echo [proxy] Exited unexpectedly. Check the error above.
pause
