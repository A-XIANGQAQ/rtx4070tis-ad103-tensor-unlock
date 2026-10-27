@echo off
rem SPDX-License-Identifier: MIT
rem Kept because README and docs call it by name; same work as "build.cmd fp8mma".
call "%~dp0build.cmd" fp8mma
exit /b %ERRORLEVEL%
