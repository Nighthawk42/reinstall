@echo off
mode con cp select=437 >nul

rem Restore setup.exe
rename X:\setup.exe.disabled setup.exe

rem Wait 10 seconds before starting the install
cls
for /l %%i in (10,-1,1) do (
    echo Press Ctrl+C within %%i seconds to cancel the automatic installation.
    call :sleep 1000
    cls
)

rem the find command misbehaves under code page 65001, win7 only
rem findstr works fine, but the installer does not ship findstr
rem echo a | find "a"

rem Use the High performance power plan
rem https://learn.microsoft.com/windows-hardware/manufacture/desktop/capture-and-apply-windows-using-a-single-wim
rem win8 pe has no powercfg
powercfg /s SCHEME_MIN 2>nul

rem Install the SCSI drivers
if exist X:\drivers\ (
    for /f "delims=" %%F in ('dir /s /b "X:\drivers\*.inf" 2^>nul') do (
        call :drvload_if_scsi "%%~F"
    )

    rem the docs say it installs, but only critical drivers get loaded
    rem Gcore's virtio-gpu shows nothing during setup
    rem even when the display driver is loaded during setup
    rem output only appears once the system boots
    rem find /i "viogpudo" "%%~F" >nul
    rem if not errorlevel 1 (
    rem     drvload "%%~F"
    rem )
)

rem Install the custom SCSI drivers
rem forfiles /p X:\custom_drivers /m *.inf /c "cmd /c echo @path" works
rem for %%F in ("X:\custom_drivers\*\*.inf") does not
if exist X:\custom_drivers\ (
    for /f "delims=" %%F in ('dir /s /b "X:\custom_drivers\*.inf" 2^>nul') do (
        call :drvload_if_scsi "%%~F"
    )
)

rem Wait for the partitions to load
call :sleep 5000
echo rescan | diskpart
call :sleep 5000

rem Get the ProductType
rem for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\ProductOptions" /v ProductType') do (
rem     set "ProductType=%%a"
rem )

rem Get the installer volume id
for /f "tokens=2" %%a in ('echo list vol ^| diskpart ^| find " installer "') do (
    set "VolIndex=%%a"
)

rem Exit promptly
if "%VolIndex%"=="" (
    echo Error: Cannot find installer partition. >&2
    exit /b 1
)

rem Assign drive letter Y to the installer partition
(echo select vol %VolIndex% & echo assign letter=Y) | diskpart

rem the old installer sets up a pagefile on C: automatically
rem the new installer (24h2) does not
rem create the pagefile on the installer partition; the space is free anyway
call :createPageFile

rem Show the pagefile
rem wmic pagefile

rem Get the main disk id
rem vista pe has no wmic, so use diskpart

rem French win7 diskpart always prints French even with chcp 437, so this approach will not work
rem (echo select vol %VolIndex% & echo list disk) | diskpart | find "* Disk " > X:\disk.txt
rem for /f "tokens=3" %%a in (X:\disk.txt) do (
rem     set "DiskIndex=%%a"
rem )

rem PE has no findstr, so the * line cannot be picked out of diskpart output directly; the disk number needs a roundabout method

rem Write the diskpart output to a file
(echo select vol %VolIndex% & echo list disk) | diskpart | find "* " > X:\disk.txt
type X:\disk.txt

rem Read the file line by line
setlocal enabledelayedexpansion
for /f "delims=" %%a in (X:\disk.txt) do (
    set "line=%%a"

    rem find the line starting with *
    call :is_x_starts_with_char_y "!line!" "*" && (
        rem note: in "for %%b in (!safe_line!) do", * expands to a file list, so strip the * first
        rem the approach below uses * as the delimiter and takes the first column after it

        rem for /f automatically ignores leading delimiters
        for /f "tokens=1 delims=*" %%i in ("!line!") do (
            set "safe_line=%%i"
        )

        rem walk the columns; the numeric one is the disk number
        for %%b in (!safe_line!) do (
            call :is_number "%%b" && (
                set "DiskIndex=%%b"
                goto :found_main_disk
            )
        )

        rem a plain for queues up each word of a string and binds one variable (%%b) to each in turn
        rem for /f splits a string into pieces held in separate variables (%%i, %%j, ...)
    )
)

:not_found_main_disk
echo Error: Cannot find main disk. >&2
exit /b 1

:found_main_disk
del X:\disk.txt
endlocal & set "DiskIndex=%DiskIndex%"

rem Determine efi or bios
rem or use https://learn.microsoft.com/windows-hardware/manufacture/desktop/boot-to-uefi-mode-or-legacy-bios-mode
rem pe has no mountvol
echo list vol | diskpart | find " efi " && (
    set BootType=efi
) || (
    set BootType=bios
)

rem this variable is rewritten by trans.sh
set is4kn=0
if "%is4kn%"=="1" (
    set EFISize=260
) else (
    set EFISize=100
)

rem Repartition / format
(if "%BootType%"=="efi" (
    echo select disk %DiskIndex%

    rem del
    echo select part 1
    echo delete part override
    echo select part 2
    echo delete part override
    echo select part 3
    echo delete part override

    rem 1
    echo create part efi size=%EFISize%
    echo format fs=fat32 quick

    rem 2
    echo create part msr size=16

    rem 3
    echo create part primary
    echo format fs=ntfs quick
    rem echo assign letter=Z

) else (
    echo select disk %DiskIndex%

    rem del
    echo select part 1
    echo delete part override

    rem 1
    echo create part primary
    echo format fs=ntfs quick
    echo active
    rem echo assign letter=Z

)) > X:\diskpart.txt

rem with diskpart /s, the remaining diskpart commands are skipped after an error
rem but the exit code is always 0
diskpart /s X:\diskpart.txt
del X:\diskpart.txt

rem Drive letter
rem X boot.wim (ram)
rem Y installer
rem Z os

rem Get the BuildNumber
for /f "tokens=3" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber') do (
    set "BuildNumber=%%a"
)

rem the old installer sets a pagefile on C: automatically, the new one (24h2) does not
rem without a pagefile, a 1G-RAM machine errors out or has processes killed during setup
if %BuildNumber% GEQ 26040 (
    rem a pagefile roughly the size of boot.wim already exists on the installer partition, so this is unnecessary
    rem vista/2008 keeps boot.wim; after the 200M reserve minus filesystem and driver usage, a 64M pagefile fits in practice
    rem call :createPageFileOnZ
)

rem Set the main disk id in the answer file
set "file=X:\windows.xml"
set "tempFile=X:\tmp.xml"

set "search=%%disk_id%%"
set "replace=%DiskIndex%"

(for /f "delims=" %%i in (%file%) do (
    set "line=%%i"

    setlocal EnableDelayedExpansion
    echo !line:%search%=%replace%!
    endlocal

)) > %tempFile%
move /y %tempFile% %file%


rem https://github.com/pbatard/rufus/issues/1990
for %%a in (RAM TPM SecureBoot) do (
    reg add HKLM\SYSTEM\Setup\LabConfig /t REG_DWORD /v Bypass%%aCheck /d 1 /f
)

rem Settings
set ForceOldSetup=0
set EnableUnattended=1
set EnableEMS=0

rem when running the ramdisk X:\setup.exe
rem vista cannot find the install source
rem server 23h2 fails to run
rem would /installfrom fix this?

rem some trimmed-down isos have no setup.exe at the root of install.wim
rem https://github.com/bin456789/reinstall/issues/578

if "%ForceOldSetup%"=="1" if exist Y:\sources\setup.exe (
    set setup=Y:\sources\setup.exe
    goto :SetupExeFound
)
if exist Y:\setup.exe (
    set setup=Y:\setup.exe
) else if exist Y:\sources\setup.exe (
    set setup=Y:\sources\setup.exe
) else if exist X:\setup.exe (
    set setup=X:\setup.exe
) else (
    echo "Error: setup.exe not found." >&2
    exit /b 1
)
:SetupExeFound

if "%EnableUnattended%"=="1" (
    set Unattended=/unattend:X:\windows.xml
)

rem the new installer enables Compact OS by default

rem the new installer does not create BIOS MBR boot records
rem so fall back to the old installer, or repair the MBR manually
rem the same applies to server 2025 + bios
rem even though the server 2025 docs claim bios support
rem TODO: could ms-sys avoid the repair?
if %BuildNumber% GEQ 26040 if "%BootType%"=="bios" (
    rem set ForceOldSetup=1
    bootrec /fixmbr
)

rem the old installer does not create a winre partition
rem the new installer does
rem and it places winre before the installer partition
rem with the winre partition disabled, winre lives on C: and still works
if %BuildNumber% GEQ 26040 if "%ForceOldSetup%"=="0" (
    set ResizeRecoveryPartition=/ResizeRecoveryPartition Disable
)

rem Enable EMS/SAC for windows server
rem desktop windows has no SAC component, so it is left alone for now
rem trans.sh now detects the SAC component accurately and sets EnableEMS when present
if "%EnableEMS%"=="1" (
    rem set EMS=/EMSPort:UseBIOSSettings /EMSBaudRate:115200
    set EMS=/EMSPort:COM1 /EMSBaudRate:115200
)

echo on
%setup% %ResizeRecoveryPartition% %EMS% %Unattended%
exit /b





:is_number
rem try to convert the string to a number; failure means it is not numeric
rem on failure num is 0
rem which does not affect the check when the argument really is 0
set /a "num=%~1" >nul 2>nul
if "%num%"=="%~1" (
    exit /b 0
)
exit /b 1

:is_x_starts_with_char_y
set "tempStr=%~1"
if "%tempStr:~0,1%"=="%~2" (
   exit /b 0
)
exit /b 1

:sleep
rem no NIC driver is loaded, so ping cannot be used to wait
rem and there is no timeout command
rem timeout /t 10 /nobreak
echo wscript.sleep(%~1) > X:\sleep.vbs
cscript //nologo X:\sleep.vbs
del X:\sleep.vbs
exit /b

:createPageFile
rem fill as much space as possible; the pagefile defaults to 64M
for /l %%i in (1, 1, 100) do (
    wpeutil CreatePageFile /path=Y:\pagefile%%i.sys >nul 2>nul && echo Created pagefile%%i.sys || exit /b
)
exit /b

:createPageFileOnZ
wpeutil CreatePageFile /path=Z:\pagefile.sys /size=512
exit /b

:drvload_if_scsi
rem do not search for Class=SCSIAdapter: some drivers have spaces around the equals sign
find /i "SCSIAdapter" "%~1" >nul
if not errorlevel 1 (
    rem there are several ways to install drivers
    rem 1. dism /online /add-driver /driver:"%~1"     # PE does not support /online
    rem 2. pnputil -i -a "%~1"
    rem 3. devcon
    rem 4. dpinst
    rem 5. drvload, the officially recommended way https://learn.microsoft.com/windows-hardware/manufacture/desktop/drvload-command-line-options
    drvload "%~1"
)
exit /b
