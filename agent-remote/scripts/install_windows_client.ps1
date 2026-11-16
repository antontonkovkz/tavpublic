#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerHost,
    [Parameter(Mandatory)][ValidateRange(1,65535)][int]$ServerPort,
    [Parameter(Mandatory)][string]$Auth,
    [Parameter(Mandatory)][string]$Fingerprint,
    [Parameter(Mandatory)][ValidateRange(1,65535)][int]$ReversePort,
    [Parameter(Mandatory)][string]$SshUser,
    [Parameter(Mandatory)][string]$SshPublicKey,
    [string]$ChiselVersion = '1.11.3'
)
$ErrorActionPreference = 'Stop'
if ($ServerHost -notmatch '^[a-zA-Z0-9.:-]+$' -or $Fingerprint -notmatch '^[a-zA-Z0-9+/=:]+$') {
    throw 'Invalid server host or fingerprint'
}
if ($SshPublicKey -notmatch '^ssh-(ed25519|rsa) [A-Za-z0-9+/=]+(?: .*)?$' -or $SshPublicKey -match '[\r\n]') {
    throw 'Expected a single OpenSSH public key'
}
# Resolve domain identities before making any changes. Token membership includes
# nested domain groups, unlike enumerating local Administrators directly.
if ($SshUser.Contains('\')) {
    $account = New-Object System.Security.Principal.NTAccount($SshUser)
    $userSid = $account.Translate([System.Security.Principal.SecurityIdentifier])
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -ne $userSid.Value) {
        throw 'For a domain account, run elevated PowerShell as that same account. Installation has not started.'
    }
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
} else {
    $userSid = (Get-LocalUser -Name $SshUser).SID
    $admins = Get-LocalGroupMember -SID 'S-1-5-32-544'
    $isAdmin = $admins.SID.Value -contains $userSid.Value
}
if (!$isAdmin) {
    $profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $userSid.Value
    if (!$profile) { throw 'Sign in as the SSH user once to create its Windows profile' }
}
$root = Join-Path $env:ProgramData 'agent-remote'
New-Item -ItemType Directory -Force $root | Out-Null
# Restrict scripts and credentials before writing them; use SIDs on localized Windows.
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE) { throw 'Unable to secure installation directory' }
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service sshd -StartupType Automatic
Start-Service sshd
if ($isAdmin) {
    $keyFile = Join-Path $env:ProgramData 'ssh/administrators_authorized_keys'
} else {
    $sshDir = Join-Path $profile.LocalPath '.ssh'
    New-Item -ItemType Directory -Force $sshDir | Out-Null
    $keyFile = Join-Path $sshDir 'authorized_keys'
}
if (!(Test-Path $keyFile)) { New-Item -ItemType File $keyFile | Out-Null }
if (@(Get-Content $keyFile) -notcontains $SshPublicKey) { Add-Content -Encoding ascii $keyFile $SshPublicKey }
& icacls.exe $keyFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
if ($LASTEXITCODE) { throw 'Unable to secure authorized_keys' }
if ($keyFile -notlike '*administrators_authorized_keys') {
    & icacls.exe $keyFile /grant:r "*$($userSid.Value):F" | Out-Null
    if ($LASTEXITCODE) { throw 'Unable to grant SSH user key access' }
}
$arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' {'amd64'} 'ARM64' {'arm64'} default {throw 'Unsupported architecture'} }
$archive = Join-Path $root 'chisel.zip'
Invoke-WebRequest -UseBasicParsing "https://github.com/jpillora/chisel/releases/download/v$ChiselVersion/chisel_${ChiselVersion}_windows_${arch}.zip" -OutFile $archive
Stop-ScheduledTask -TaskName 'AgentRemoteTunnel' -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $archive -DestinationPath $root -Force
if (!(Test-Path -LiteralPath (Join-Path $root 'chisel.exe') -PathType Leaf)) {
    throw 'Downloaded archive does not contain chisel.exe'
}
@{ ServerHost=$ServerHost; ServerPort=$ServerPort; Auth=$Auth; Fingerprint=$Fingerprint; ReversePort=$ReversePort } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $root 'client.json')
@'
$ErrorActionPreference = 'Stop'
$c = Get-Content -Raw (Join-Path $PSScriptRoot 'client.json') | ConvertFrom-Json
$p = New-Object Diagnostics.ProcessStartInfo
$p.FileName = Join-Path $PSScriptRoot 'chisel.exe'
$p.UseShellExecute = $false
$p.CreateNoWindow = $true
$p.RedirectStandardOutput = $true
$p.RedirectStandardError = $true
$p.EnvironmentVariables['AUTH'] = $c.Auth
$p.Arguments = 'client --fingerprint "' + $c.Fingerprint + '" "' + $c.ServerHost + ':' + $c.ServerPort + '" R:127.0.0.1:' + $c.ReversePort + ':127.0.0.1:22'
$process = [Diagnostics.Process]::Start($p)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
$process.WaitForExit()
$stdout.Result + $stderr.Result | Set-Content (Join-Path $PSScriptRoot 'tunnel.log')
exit 1
'@ | Set-Content -Encoding UTF8 (Join-Path $root 'run-tunnel.ps1')
$exe = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$root\run-tunnel.ps1`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName 'AgentRemoteTunnel' -Action $action -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'AgentRemoteTunnel'
Write-Output 'Windows client installed. Tunnel runs as SYSTEM outside the interactive desktop.'
