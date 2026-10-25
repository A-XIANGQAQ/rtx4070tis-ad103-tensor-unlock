@echo off
if defined VCINSTALLDIR goto :havevc
call "%VCVARS64%" >nul 2>&1
:havevc
if errorlevel 1 exit /b 1
cd /d "%~dp0"
nvcc -O3 -arch=sm_89 -std=c++17 -o fp8_mma_bench.exe fp8_mma_bench.cu 2>&1 | findstr /V "C4819"
if errorlevel 1 exit /b 1
echo BUILD-OK
