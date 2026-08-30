@echo off
mode con cp select=437 >nul
setlocal EnableDelayedExpansion

set confhome=https://raw.githubusercontent.com/Nighthawk42/reinstall/main

set pkgs=curl,cpio,p7zip,dos2unix,jq,xz,gzip,zstd,openssl,bind-utils,libiconv,binutils
set cmds=curl,cpio,p7zip,dos2unix,jq,xz,gzip,zstd,openssl,nslookup,iconv,ar

rem code page 65001 produces garbled output

rem do not use :: for comments
rem it can produce "The system cannot find the drive specified"

rem winhttp on Windows 7 SP1 does not support tls 1.2 by default
rem https://support.microsoft.com/en-us/topic/update-to-enable-tls-1-1-and-tls-1-2-as-default-secure-protocols-in-winhttp-in-windows-c4bd73d2-31d7-761e-0178-11268bb10392
rem some systems have outdated root certificates
rem so do not use https
rem change into the script directory
cd /d %~dp0

rem check for administrator privileges
fltmc >nul 2>&1
if errorlevel 1 (
    echo Please run as administrator^^!
    exit /b
)

rem sometimes %tmp% includes a session id and the folder does not exist
rem https://learn.microsoft.com/troubleshoot/windows-server/shell-experience/temp-folder-with-logon-session-id-deleted
rem if not exist %tmp% (
rem     md %tmp%
rem )

rem Cygwin package mirror
rem Server is in an Equinix facility in the US, not a CDN
set mirror=http://mirrors.kernel.org

call :check_cygwin_installed || (
    rem win10 arm can run x86 binaries
    rem win11 arm can run x86 and x86_64 binaries

    rem windows 11 24h2 has no wmic
    rem "wmic os get osarchitecture" prints a localized string even with mode con cp select=437
    rem "wmic ComputerSystem get SystemType" prints English
    rem for /f "tokens=*" %%a in ('wmic ComputerSystem get SystemType ^| find /i "based"') do (
    rem     set "SystemType=%%a"
    rem )

    rem some systems have powershell stripped out
    rem for /f "delims=" %%a in ('powershell -NoLogo -NoProfile -NonInteractive -Command "(Get-WmiObject win32_computersystem).SystemType"') do (
    rem     set "SystemType=%%a"
    rem )

    rem SystemArch
    for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v PROCESSOR_ARCHITECTURE') do (
        set SystemArch=%%a
    )

    rem PROCESSOR_ARCHITEW6432 and PROCESSOR_ARCHITECTURE could also be used
    rem ARM64 win11  PROCESSOR_ARCHITEW6432   PROCESSOR_ARCHITECTURE
    rem native cmd       undefined                   ARM64
    rem 32-bit cmd       ARM64                       x86

    rem if defined PROCESSOR_ARCHITEW6432 (
    rem     set "SystemArch=%PROCESSOR_ARCHITEW6432%"
    rem ) else (
    rem     set "SystemArch=%PROCESSOR_ARCHITECTURE%"
    rem )

    rem BuildNumber
    for /f "tokens=3" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber') do (
        set /a BuildNumber=%%a
    )

    set CygwinEOL=1

    echo !SystemArch! | find "ARM" > nul
    if not errorlevel 1 (
        if !BuildNumber! GEQ 22000 (
            set CygwinEOL=0
        )
    ) else (
        echo !SystemArch! | find "AMD64" > nul
        if not errorlevel 1 (
            if !BuildNumber! GEQ 9600 (
                set CygwinEOL=0
            )
        )
    )

    rem cygwin is EOL on win7/8, so the current cygwin repo cannot be used; use Cygwin Time Machine
    rem Cygwin Time Machine has no mirror network,
    rem so EOL cygwin uniformly uses the cygwin-archive x86 repo
    if !CygwinEOL! == 1 (
        set CygwinArch=x86
        set dir=/sourceware/cygwin-archive/20221123
    ) else (
        set CygwinArch=x86_64
        set dir=/sourceware/cygwin
    )

    if not exist setup-!CygwinArch!.exe (
        call :download http://www.cygwin.com/setup-!CygwinArch!.exe %~dp0setup-!CygwinArch!.exe || goto :download_failed
    )

    rem smaller than 1M is treated as invalid
    rem some IPs are blocked by the official site and get html instead of the exe
    for %%A in (setup-!CygwinArch!.exe) do if %%~zA LSS 1048576 (
        echo Invalid Cgywin installer
        del setup-!CygwinArch!.exe
        exit /b 1
    )

    rem Install Cygwin
    set site=!mirror!!dir!
    start /wait setup-!CygwinArch!.exe ^
        --allow-unsupported-windows ^
        --quiet-mode ^
        --only-site ^
        --site !site! ^
        --root %SystemDrive%\cygwin ^
        --local-package-dir %~dp0cygwin-local-package-dir ^
        --packages %pkgs%

    rem verify Cygwin installed successfully
    if errorlevel 1 goto :install_cygwin_failed
    call :check_cygwin_installed || goto :install_cygwin_failed
)

rem running "cygpath -ua ." in C:\ yields /cygdrive/c, so a trailing / is required
for /f %%a in ('%SystemDrive%\cygwin\bin\cygpath -ua ./') do set thisdir=%%a

rem Download reinstall.sh
if not exist reinstall.sh (
    call :download_with_curl %confhome%/reinstall.sh %thisdir%reinstall.sh || goto :download_failed
    call :chmod a+x %thisdir%reinstall.sh
)

rem %* cannot handle --iso https://x.com/?yyy=123
rem quote each argument so they reach bash intact
rem for %%a in (%*) do (
rem     set "param=!param! "%%~a""
rem )

rem convert to unix line endings, in case the user edited the file in Windows Notepad
%SystemDrive%\cygwin\bin\dos2unix -q '%thisdir%reinstall.sh'

rem run it with bash
rem "%SystemDrive%\cygwin\bin\bash -l %thisdir%reinstall.sh %*" clears the screen
rem so -l cannot be used
rem which means reinstall.sh has to run "source /etc/profile"
rem or add export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
%SystemDrive%\cygwin\bin\bash %thisdir%reinstall.sh %*
exit /b

rem bits requires a Content-Length in order to download
rem cloudflare's cdn-cgi/trace has no Content-Length
rem reportedly bits also fails when the connection is set to metered
rem https://learn.microsoft.com/en-us/windows/win32/bits/http-requirements-for-bits-downloads
rem bitsadmin /transfer "%~3" /priority foreground %~1 %~2

:download
rem certutil gets flagged by Windows Defender
rem windows server 2019 needs the second certutil command
echo Downloading: %~1 %~2
del /q "%~2" 2>nul
if exist "%~2" (echo Cannot delete %~2 & exit /b 1)

certutil -urlcache -f -split "%~1" "%~2" >nul
if not errorlevel 1 if exist "%~2" exit /b 0

certutil -urlcache -split "%~1" "%~2" >nul
if not errorlevel 1 if exist "%~2" exit /b 0

rem delete the file on failure, so a partial download is not reused next run
del /q "%~2" 2>nul
exit /b 1

:download_with_curl
rem --insecure is added to avoid the following error
rem curl: (77) error setting certificate verify locations:
rem   CAfile: /etc/ssl/certs/ca-certificates.crt
rem   CApath: none
echo Download: %~1 %~2
%SystemDrive%\cygwin\bin\curl -L --insecure "%~1" -o "%~2"
exit /b

:chmod
%SystemDrive%\cygwin\bin\chmod "%~1" "%~2"
exit /b

:download_failed
echo Download failed.
exit /b 1

:install_cygwin_failed
echo Failed to install Cygwin.
exit /b 1

:check_cygwin_installed
set "cmds_space=%cmds:,= %"
for %%c in (%cmds_space%) do (
    if not exist "%SystemDrive%\cygwin\bin\%%c" if not exist "%SystemDrive%\cygwin\bin\%%c.exe" (
        exit /b 1
    )
)
exit /b 0
