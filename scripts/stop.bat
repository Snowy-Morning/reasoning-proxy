@echo off
cd /d "%~dp0"
if exist "%~dp0..\config\config.bat" call "%~dp0..\config\config.bat"

set STOPPED=0
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PROXY_PORT% *.*LISTENING"') do (
    taskkill /F /PID %%P >nul 2>&1
    echo [proxy] Stopped proxy process PID %%P on port %PROXY_PORT%.
    set STOPPED=1
)

if "%STOPPED%"=="1" (
    echo [proxy] Proxy on port %PROXY_PORT% has been stopped.
) else (
    echo [proxy] No proxy is running on port %PROXY_PORT%.
)
pause
