@echo off
rem SPDX-License-Identifier: MIT
rem Kept because README and docs call it by name; same work as "build.cmd cublas".
call "%~dp0build.cmd" cublas
exit /b %ERRORLEVEL%
