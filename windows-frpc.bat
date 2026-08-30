@echo off
mode con cp select=437 >nul

rem Windows Defender false-positives on this, so add an exclusion
powershell -ExecutionPolicy Bypass -Command "Add-MpPreference -ExclusionPath '%SystemDrive%\frpc\frpc.exe'"

rem Enable logging
rem wevtutil set-log Microsoft-Windows-TaskScheduler/Operational /enabled:true

rem Create the scheduled task and run it immediately
schtasks /Create /TN "frpc" /XML "%SystemDrive%\frpc\frpc.xml"
schtasks /Run /TN "frpc"
del "%SystemDrive%\frpc\frpc.xml"

rem On win10+, a task running as LocalService only takes effect after the first user logon
rem Even after a manual reboot the task does not run

rem If an frpc process appears within 10 seconds the task already works, no logon needed
rem If there is still no frpc process after 10 seconds, temporarily run it as SYSTEM
for /L %%i in (1,1,10) do (
    timeout 1
    tasklist /FI "IMAGENAME eq frpc.exe" | find /I "frpc.exe" && (
        goto :end
    )
)

rem Temporarily run the scheduled task as SYSTEM
schtasks /Change /TN frpc /RU S-1-5-18
schtasks /Run /TN frpc

rem Switch back to LocalService after the user logs on
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /f ^
    /v FrpcRunAsLocalService ^
    /t REG_SZ ^
    /d "schtasks /Change /TN frpc /RU S-1-5-19"

:end
rem Delete this script
del "%~f0"
