@echo off
if defined VCINSTALLDIR goto :havevc
call "%VCVARS64%" >nul 2>&1
:havevc
cd /d "%~dp0"
nvcc -O3 -arch=sm_89 --use_fast_math -o cublas_gemm.exe cublas_gemm.cu -lcublas
exit /b %ERRORLEVEL%
