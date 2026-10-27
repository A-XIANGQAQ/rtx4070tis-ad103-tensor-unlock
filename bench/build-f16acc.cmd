@echo off
rem Kept for symmetry; same work as "build.cmd f16acc".
call "%~dp0build.cmd" f16acc
exit /b %ERRORLEVEL%
