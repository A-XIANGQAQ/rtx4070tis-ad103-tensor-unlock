@echo off
rem Builds the CUDA probes in this directory. The .exe files are not tracked.
rem   build.cmd cublas    cuBLAS GEMM throughput (N, iters, reps)
rem   build.cmd fp8mma    FP8 e4m3 issue rate through mma.m16n8k32
rem   build.cmd fp8gemm   FP8 e4m3 GEMM through cuBLASLt
rem   build.cmd f16acc    why a float alpha breaks a 16F accumulate GEMM
rem   build.cmd all       all four
setlocal
set "TARGET=%~1"
if "%TARGET%"=="" goto :usage
if /i "%TARGET%"=="all" goto :all
call :one %TARGET%
exit /b %ERRORLEVEL%

:all
set "RC=0"
for %%t in (cublas fp8mma fp8gemm f16acc) do call :seq %%t
exit /b %RC%

:seq
call :one %~1
if errorlevel 1 set "RC=1"
exit /b 0

:usage
echo usage: build.cmd ^<cublas^|fp8mma^|fp8gemm^|f16acc^|all^>
exit /b 2

:one
set "NAME=%~1"
if /i "%NAME%"=="cublas"  goto :t_cublas
if /i "%NAME%"=="fp8mma"  goto :t_fp8mma
if /i "%NAME%"=="fp8gemm" goto :t_fp8gemm
if /i "%NAME%"=="f16acc"  goto :t_f16acc
echo unknown target: %NAME%
exit /b 2

:t_cublas
set "SRC=cublas_gemm.cu"
set "EXE=cublas_gemm.exe"
set "LIBS=-lcublas"
set "OPT=--use_fast_math"
goto :build

:t_fp8mma
set "SRC=fp8_mma_bench.cu"
set "EXE=fp8_mma_bench.exe"
set "LIBS="
set "OPT="
goto :build

:t_fp8gemm
set "SRC=fp8_bench.cu"
set "EXE=fp8_bench.exe"
set "LIBS=-lcublasLt"
set "OPT="
goto :build

:t_f16acc
set "SRC=probe_f16acc.cu"
set "EXE=probe_f16acc.exe"
set "LIBS=-lcublas"
set "OPT="
goto :build

:build
call :findvc
if not defined VCINSTALLDIR goto :novc
cd /d "%~dp0"
set "LOG=%TEMP%\build-%NAME%.log"
rem A failed build must not leave the previous exe looking fresh.
if exist %EXE% del /q %EXE%
nvcc -O3 -arch=sm_89 -std=c++17 %OPT% -o %EXE% %SRC% %LIBS% > "%LOG%" 2>&1
if errorlevel 1 goto :buildfail
findstr /V "C4819" "%LOG%"
echo BUILD-OK %EXE%
exit /b 0

:buildfail
findstr /V "C4819" "%LOG%"
echo BUILD-FAILED see "%LOG%"
exit /b 1

:findvc
if defined VCVARS64 if exist "%VCVARS64%" call "%VCVARS64%" >nul 2>&1
if defined VCINSTALLDIR exit /b 0
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" call "%%i\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if defined VCINSTALLDIR exit /b 0
for %%d in ("%ProgramFiles%\Microsoft Visual Studio\2022\Community") do if exist "%%~d\VC\Auxiliary\Build\vcvars64.bat" call "%%~d\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
exit /b 0

:novc
echo Could not find vcvars64.bat.
echo Set VCVARS64 to its full path, or run from a Developer Command Prompt.
exit /b 1
