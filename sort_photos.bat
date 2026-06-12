@echo off
:: sort_photos.bat — Double-click this on Windows to sort photos.
:: Drop this file (along with sort_photos.py) into any photo folder and double-click.

title Photo Sorter

:: Move to the folder this script lives in
cd /d "%~dp0"

echo ===============================
echo    Photo Sorter — Windows
echo ===============================
echo.

:: Try python, then py launcher
where python >nul 2>&1
if %errorlevel% == 0 (
    python sort_photos.py
    goto done
)

where py >nul 2>&1
if %errorlevel% == 0 (
    py sort_photos.py
    goto done
)

echo Python 3 is not installed.
echo.
echo Install it from https://www.python.org/downloads/
echo Make sure to check "Add Python to PATH" during install.

:done
echo.
pause
