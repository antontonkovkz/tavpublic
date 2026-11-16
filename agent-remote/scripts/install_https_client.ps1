param(
    [Parameter(Mandatory)][string]$Pythonw,
    [Parameter(Mandatory)][string]$ConfigFile,
    [switch]$CurrentUser
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $Pythonw) -or (Split-Path $Pythonw -Leaf) -ne 'pythonw.exe') {
    throw 'Supply the absolute path to pythonw.exe (Python 3.10 or newer, installed for all users)'
}
$config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
if ($config.url -notmatch '^https://') { throw 'Client URL must use HTTPS' }
if (!$config.token -or $config.token.Length -lt 32) { throw 'A client token of at least 32 characters is required' }
if (!$config.workers) { $config | Add-Member workers 4 }
if ($config.workers -lt 1 -or $config.workers -gt 32) { throw 'workers must be between 1 and 32' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (!$CurrentUser -and !([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'SYSTEM installation requires elevated PowerShell; use -CurrentUser for a user task'
}
$root = if ($CurrentUser) { Join-Path $env:LOCALAPPDATA 'agent-remote-https' } else { Join-Path $env:ProgramData 'agent-remote-https' }
New-Item -ItemType Directory -Path $root -Force | Out-Null
$grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
if ($CurrentUser) { $grants += "*$($identity.User.Value):(OI)(CI)F" }
& icacls.exe $root /inheritance:r /grant:r @grants | Out-Null
if ($LASTEXITCODE) { throw 'Cannot secure installation directory' }
$taskName = if ($CurrentUser) { 'AgentRemoteHTTPSUser' } else { 'AgentRemoteHTTPS' }
Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\https_remote.py') -Destination $root -Force
$config | Add-Member spool (Join-Path $root 'results') -Force
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'client.json') -Encoding UTF8
$action = New-ScheduledTaskAction -Execute ([IO.Path]::GetFullPath($Pythonw)) -Argument "`"$root\https_remote.py`" client --config `"$root\client.json`"" -WorkingDirectory $root
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
if ($CurrentUser) {
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
} else {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings -User SYSTEM -RunLevel Highest -Force | Out-Null
}
Start-ScheduledTask -TaskName $taskName
Write-Output "$taskName installed and started. Directory: $root"
if (!$CurrentUser) { Write-Output 'Commands have SYSTEM privileges.' }
