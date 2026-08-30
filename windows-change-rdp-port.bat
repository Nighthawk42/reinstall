@echo off
mode con cp select=437 >nul

rem set RdpPort=3333

rem https://learn.microsoft.com/windows-server/remote/remote-desktop-services/clients/change-listening-port
rem HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules

rem RemoteDesktop-Shadow-In-TCP
rem v2.33|Action=Allow|Active=TRUE|Dir=In|Protocol=6|App=%SystemRoot%\system32\RdpSa.exe|Name=@FirewallAPI.dll,-28778|Desc=@FirewallAPI.dll,-28779|EmbedCtxt=@FirewallAPI.dll,-28752|Edge=TRUE|Defer=App|

rem RemoteDesktop-UserMode-In-TCP
rem v2.33|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=3389|App=%SystemRoot%\system32\svchost.exe|Svc=termservice|Name=@FirewallAPI.dll,-28775|Desc=@FirewallAPI.dll,-28756|EmbedCtxt=@FirewallAPI.dll,-28752|

rem RemoteDesktop-UserMode-In-UDP
rem v2.33|Action=Allow|Active=TRUE|Dir=In|Protocol=17|LPort=3389|App=%SystemRoot%\system32\svchost.exe|Svc=termservice|Name=@FirewallAPI.dll,-28776|Desc=@FirewallAPI.dll,-28777|EmbedCtxt=@FirewallAPI.dll,-28752|

rem Set the port
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber /t REG_DWORD /d %RdpPort% /f

rem Configure the firewall
rem The built-in rdp firewall rules differ slightly between versions
rem All versions have: program=%SystemRoot%\system32\svchost.exe service=TermService
rem win7 also has:    program=System                            service=
rem The following is the union of both
for %%a in (TCP, UDP) do (
    netsh advfirewall firewall add rule ^
        name="Remote Desktop - Custom Port (%%a-In)" ^
        dir=in ^
        action=allow ^
        service=any ^
        protocol=%%a ^
        localport=%RdpPort%
)

rem Home editions have no rdp service
sc query TermService
if %errorlevel% == 1060 goto :del

rem The service can be restarted with either sc or net
rem UmRdpService depends on TermService
rem sc stop does not handle dependencies, so stop UmRdpService before TermService
rem net stop does handle dependencies
rem sc stop is asynchronous; net stop is not, but it has a timeout
rem Once TermService is running, UmRdpService starts automatically

rem This fails if the system happens to be starting the rdp service, hence the goto retry loop
rem The Remote Desktop Services service could not be stopped.

rem Some machines loop forever, spinning on the boot logo
rem netstat -ano shows the port was changed, but the rdp service keeps restarting (the pid keeps changing)
rem So cap the retry count to avoid an infinite loop

set retryCount=5

:restartRDP
if %retryCount% LEQ 0 goto :del
net stop TermService /y && net start TermService || (
    set /a retryCount-=1
    timeout 10
    goto :restartRDP
)

:del
del "%~f0"
