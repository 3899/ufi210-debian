@echo off
chcp 65001 >nul
title UFI210 / MSM8909 ADB 连接工具
cd /d "%~dp0"

echo ================================================================
echo           UFI210 / MSM8909 随身WiFi ADB 连接工具
echo ================================================================
echo.

set "DEVICE_IP=%~1"
if "%DEVICE_IP%"=="" set "DEVICE_IP=192.168.68.1"
set "PORT=%~2"
if "%PORT%"=="" set "PORT=5555"

set "TARGET=%DEVICE_IP%:%PORT%"

set "ADB_BIN=adb.exe"
if exist "%~dp0adb.exe" set "ADB_BIN=%~dp0adb.exe"

echo [*] 正在连接目标设备: %TARGET% ...
"%ADB_BIN%" disconnect %TARGET% >nul 2>&1
"%ADB_BIN%" connect %TARGET%

if errorlevel 1 (
    echo.
    echo [X] 连接失败，请检查：
    echo     1. 设备是否已通电并正常启动
    echo     2. 是否已连入 192.168.68.x 网段（USB RNDIS）或设备 Wi-Fi 局域网
    echo.
    pause
    exit /b 1
)

echo.
echo [V] 已成功连接到 %TARGET%
echo [*] 正在启动 root shell 终端 (输入 exit 退出)...
echo.
"%ADB_BIN%" -s %TARGET% shell
if errorlevel 1 (
    echo.
    echo [*] 会话已结束。
    pause
)
