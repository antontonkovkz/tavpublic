#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\windows-diagnostics.txt')
)
$ErrorActionPreference = 'Continue'
$root = Join-Path $env:ProgramData 'agent-remote'
$report = New-Object System.Collections.Generic.List[string]
$secrets = @()
$config = $null
try {
    $config = Get-Content -LiteralPath (Join-Path $root 'client.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($config.Auth) { $secrets += [string]$config.Auth }
} catch { }
function Add-Section([string]$Title, [scriptblock]$Body) {
    $report.Add("`r`n=== $Title ===")
    try {
        $value = (& $Body 2>&1 | Out-String -Width 200)
    } catch { $value = $_ | Out-String }
    foreach ($secret in $secrets) {
        if ($secret) { $value = $value.Replace($secret, '[REDACTED]') }
    }
    $value = $value -replace '(?im)(--auth\s+|AUTH\s*[=:]\s*|"Auth"\s*:\s*)[^\r\n]+', '$1[REDACTED]'
    $value = $value -replace '(?i)(https?://)[^\s/@]+:[^\s/@]+@', '$1[REDACTED]@'
    $report.Add($value.TrimEnd())
}
Add-Section 'Time and identity' {
    Get-Date -Format o
    whoami
    hostname
}
Add-Section 'OpenSSH service and listener' {
    Get-Service sshd -ErrorAction Stop | Format-List Name, Status, StartType
    Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction Stop |
        Format-Table LocalAddress, LocalPort, OwningProcess
}
Add-Section 'Tunnel scheduled task' {
    $task = Get-ScheduledTask -TaskName AgentRemoteTunnel -ErrorAction Stop
    $task | Format-List TaskName, State
    $task.Principal | Format-List UserId, LogonType, RunLevel
    # Arguments and environment may contain credentials; deliberately omit them.
    $task.Actions | Select-Object Execute, WorkingDirectory | Format-List
    $task.Settings | Format-List RestartCount, RestartInterval, ExecutionTimeLimit
    Get-ScheduledTaskInfo -TaskName AgentRemoteTunnel -ErrorAction Stop |
        Format-List LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns
}
Add-Section 'Installed files' {
    Get-ChildItem -LiteralPath $root -ErrorAction Stop |
        Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
    if (Test-Path (Join-Path $root 'chisel.exe')) {
        Get-FileHash -LiteralPath (Join-Path $root 'chisel.exe') -Algorithm SHA256 | Format-List
    }
}
Add-Section 'Tunnel process' {
    Get-Process chisel -ErrorAction Stop | Select-Object Id, Path, StartTime | Format-List
}
Add-Section 'Server connection' {
    if (!$config) { throw 'client.json is missing, unreadable, or invalid' }
    "Server: $($config.ServerHost):$($config.ServerPort)"
    "Reverse port: $($config.ReversePort)"
    Test-NetConnection -ComputerName $config.ServerHost -Port $config.ServerPort -WarningAction SilentlyContinue |
        Select-Object ComputerName, RemoteAddress, RemotePort, TcpTestSucceeded | Format-List
}
Add-Section 'Tunnel log (last 60 lines)' {
    Get-Content -LiteralPath (Join-Path $root 'tunnel.log') -Tail 60 -ErrorAction Stop
}
Add-Section 'Recent OpenSSH events' {
    Get-WinEvent -FilterHashtable @{ LogName='OpenSSH/Operational'; StartTime=(Get-Date).AddHours(-2) } -MaxEvents 15 -ErrorAction Stop |
        Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
}
Add-Section 'Recent Defender detections' {
    Get-MpThreatDetection -ErrorAction Stop |
        Where-Object InitialDetectionTime -gt (Get-Date).AddDays(-1) |
        Select-Object InitialDetectionTime, ThreatID, ActionSuccess, Resources | Format-List
}
$report.Add("`r`nNote: a missing tunnel.log can be normal while the tunnel is running. LastTaskResult 267009 (0x41301) means the task is running.")
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$report | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8 -ErrorAction Stop
Write-Output "Diagnostic report saved: $resolvedOutput"
Write-Output 'No services, tasks, firewall rules, or security settings were changed.'
