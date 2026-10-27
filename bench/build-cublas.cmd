@echo off
setlocal
call :findvc
if not defined VCINSTALLDIR goto :novc
cd /d "%~dp0"

set "LOG=%TEMP%\%~n0.log"
rem A failed build must not leave the previous exe looking fresh.
if exist cublas_gemm.exe del /q cublas_gemm.exe
nvcc -O3 -arch=sm_89 --use_fast_math -o cublas_gemm.exe cublas_gemm.cu -lcublas > "%LOG%" 2>&1
if errorlevel 1 goto :buildfail
findstr /V "C4819" "%LOG%"
echo BUILD-OK
exit /b 0

:buildfail
findstr /V "C4819" "%LOG%"
echo BUILD-FAILED see "%LOG%"
exit /b 1

exit /b 0

:findvc
if defined VCVARS64 if exist "%VCVARS64%" call "%VCVARS64%" >nul 2>&1
if defined VCINSTALLDIR exit /b 0
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" call "%%i\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if defined VCINSTALLDIR exit /b 0
for %%d in ("%ProgramFiles%\Microsoft Visual Studio\2022\Community" "D:\Program Files\Microsoft Visual Studio\18\Community") do if exist "%%~d\VC\Auxiliary\Build\vcvars64.bat" call "%%~d\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
exit /b 0

:novc
echo Could not find vcvars64.bat.
echo Set VCVARS64 to its full path, or run from a Developer Command Prompt.
exit /b 1
