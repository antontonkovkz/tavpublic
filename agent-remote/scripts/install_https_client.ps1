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
$Pythonw = (Resolve-Path -LiteralPath $Pythonw).Path
if (!$CurrentUser) {
    $programRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    $programRoot = $programRoots | Where-Object { $Pythonw.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if (!$programRoot) { throw 'SYSTEM requires Python installed in Program Files, not a user profile' }
    $pythonDirectory = Split-Path $Pythonw
    $trustedWriters = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $writeMask = [Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    # Include libraries/DLLs as well as pythonw.exe: a writable import is also SYSTEM code execution.
    $paths = @((Get-Item -LiteralPath $pythonDirectory)) + @(Get-ChildItem -LiteralPath $pythonDirectory -Recurse -Force)
    $ancestor = Get-Item -LiteralPath (Split-Path $pythonDirectory)
    while ($ancestor -and $ancestor.FullName.Length -ge $programRoot.Length) { $paths += $ancestor; $ancestor = $ancestor.Parent }
    foreach ($item in $paths) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "SYSTEM Python cannot use reparse points: $($item.FullName)" }
        $acl = Get-Acl -LiteralPath $item.FullName
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin $trustedWriters) { throw "Untrusted owner in SYSTEM Python path: $($item.FullName)" }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if (!(($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and $rule.IdentityReference.Value -eq 'S-1-3-0') -and $rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writeMask) -and $rule.IdentityReference.Value -notin $trustedWriters) {
                throw "Non-administrator write access in SYSTEM Python path: $($item.FullName)"
            }
        }
    }
}
$policy = Get-ExecutionPolicy
if ($policy -in @('Restricted', 'AllSigned')) {
    throw "ExecutionPolicy $policy prevents unsigned job files. Inspect Get-ExecutionPolicy -List and use an approved policy/signing setup. No policy was changed."
}
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { throw 'PowerShell FullLanguage mode is required; inspect AppLocker/WDAC policy' }
$root = if ($CurrentUser) { Join-Path $env:LOCALAPPDATA 'agent-remote-https' } else { Join-Path $env:ProgramData 'agent-remote-https' }
if (Test-Path -LiteralPath $root) {
    $existing = @((Get-Item -LiteralPath $root)) + @(Get-ChildItem -LiteralPath $root -Recurse -Force)
    foreach ($item in $existing) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Installation cannot follow reparse points: $($item.FullName)" }
        if (!$CurrentUser) {
            $acl = Get-Acl -LiteralPath $item.FullName
            if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trustedWriters) { throw "Untrusted installation file owner: $($item.FullName)" }
            foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
                if (!(($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and $rule.IdentityReference.Value -eq 'S-1-3-0') -and $rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writeMask) -and $rule.IdentityReference.Value -notin $trustedWriters) {
                    throw "Untrusted installation write access: $($item.FullName)"
                }
            }
        }
    }
}
New-Item -ItemType Directory -Path $root -Force | Out-Null
$grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
if ($CurrentUser) { $grants += "*$($identity.User.Value):(OI)(CI)F" }
& icacls.exe $root /inheritance:r /grant:r @grants | Out-Null
if ($LASTEXITCODE) { throw 'Cannot secure installation directory' }
$taskName = if ($CurrentUser) { 'AgentRemoteHTTPSUser' } else { 'AgentRemoteHTTPS' }
Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\https_remote.py') -Destination $root -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\windows_job.py') -Destination $root -Force
$config | Add-Member spool (Join-Path $root 'results') -Force
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'client.json') -Encoding UTF8
$action = New-ScheduledTaskAction -Execute ([IO.Path]::GetFullPath($Pythonw)) -Argument "`"$root\https_remote.py`" client --config `"$root\client.json`"" -WorkingDirectory $root
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
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
