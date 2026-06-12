@echo off
:: build_windows.bat — Builds PhotoSorter.exe for Windows (no prerequisites needed to run)
:: Run this ONCE on a Windows machine. Requires Python 3 + pip.

title Photo Sorter - Windows Build
cd /d "%~dp0"

echo =======================================
echo    Photo Sorter — Windows Build
echo =======================================
echo.

echo Installing dependencies...
pip install --quiet --upgrade customtkinter pyinstaller
if %errorlevel% neq 0 (
    echo ERROR: pip failed. Make sure Python 3 is installed and on PATH.
    pause & exit /b 1
)

echo.
echo Building PhotoSorter.exe...

pyinstaller ^
    --noconfirm ^
    --windowed ^
    --onefile ^
    --name "PhotoSorter" ^
    --collect-data customtkinter ^
    --collect-data darkdetect ^
    photo_sorter_app.py

echo.
echo =======================================
echo  Build complete!
echo.
echo  Your app is at:  dist\PhotoSorter.exe
echo  Share that single .exe file — no install needed.
echo =======================================
echo.

start dist\
pause
