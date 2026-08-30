rem set mac_addr=11:22:33:aa:bb:cc

rem set ipv4_addr=192.168.1.2/24
rem set ipv4_gateway=192.168.1.1
rem set ipv4_dns1=192.168.1.1
rem set ipv4_dns2=192.168.1.2

rem set ipv6_addr=2222::2/64
rem set ipv6_gateway=2222::1
rem set ipv6_dns1=::1
rem set ipv6_dns2=::2

@echo off
mode con cp select=437 >nul

rem Disable IPv6 interface identifier randomization, so the IPv6 address matches the provider panel
netsh interface ipv6 set global randomizeidentifiers=disabled

rem Check whether a MAC address was defined
if not defined mac_addr goto :del

rem vista does not ship with powershell
rem win11 24h2 has wmic right after install but removes it later, so some dd images lack wmic
if exist "%windir%\system32\wbem\wmic.exe" (
    rem wmic uses \r\r\n line endings
    rem even with a findstr whole-word match there is still a trailing \r
    for /f "tokens=2 delims==" %%a in (
        'wmic nic where "MACAddress='%mac_addr%'" get InterfaceIndex /format:list ^| findstr "^InterfaceIndex=[0-9][0-9]*$"'
    ) do set id=%%a
)

if not defined id (
    for /f %%a in ('powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
        -Command "(Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.MACAddress -eq '%mac_addr%' }).InterfaceIndex" ^| findstr "^[0-9][0-9]*$"'
    ) do set id=%%a
)

if not defined id (
    for /f %%a in ('powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
        -Command "(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.MACAddress -eq '%mac_addr%' }).InterfaceIndex" ^| findstr "^[0-9][0-9]*$"'
    ) do set id=%%a
)

if defined id (
    rem Configure the static IPv4 address and gateway
    if defined ipv4_addr if defined ipv4_gateway (
        rem When setlocal EnableDelayedExpansion is in effect,
        rem netsh interface ipv4 set address !id! static %ipv4_addr% gateway=%ipv4_gateway% gwmetric=0
        rem a trailing \r in !id! makes the statement malformed
        rem %id% does not have this problem

        rem gwmetric defaults to 1; set it to 0 for an automatic metric
        netsh interface ipv4 set address %id% static %ipv4_addr% gateway=%ipv4_gateway% gwmetric=0
    )

    rem Configure the static IPv4 DNS servers
    for %%i in (1, 2) do (
        if defined ipv4_dns%%i (
            netsh interface ipv4 add | findstr "dnsservers" >nul
            if ErrorLevel 1 (
                rem vista
                setlocal EnableDelayedExpansion
                netsh interface ipv4 add dnsserver %id% !ipv4_dns%%i! %%i
                endlocal
            ) else (
                rem win7
                setlocal EnableDelayedExpansion
                netsh interface ipv4 add dnsservers %id% !ipv4_dns%%i! %%i no
                endlocal
            )
        )
    )

    rem Configure the IPv6 address and gateway
    if defined ipv6_addr if defined ipv6_gateway (
        netsh interface ipv6 set address %id% %ipv6_addr%
        netsh interface ipv6 add route prefix=::/0 %id% %ipv6_gateway%
    )

    rem Configure the IPv6 DNS servers
    for %%i in (1, 2) do (
        if defined ipv6_dns%%i (
            netsh interface ipv6 add | findstr "dnsservers" >nul
            if ErrorLevel 1 (
                rem vista
                setlocal EnableDelayedExpansion
                netsh interface ipv6 add dnsserver %id% !ipv6_dns%%i! %%i
                endlocal
            ) else (
                rem win7
                setlocal EnableDelayedExpansion
                netsh interface ipv6 add dnsservers %id% !ipv6_dns%%i! %%i no
                endlocal
            )
        )
    )
)

:del
rem Delete this script
del "%~f0"
