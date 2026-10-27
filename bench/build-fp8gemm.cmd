@echo off
rem Kept for symmetry; same work as "build.cmd fp8gemm".
call "%~dp0build.cmd" fp8gemm
exit /b %ERRORLEVEL%
