[CmdletBinding()]
param([switch]$SkipAutologon, [switch]$Serve)

$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'WindowsMcpVm'
$taskName = 'Windows-MCP Desktop'
$tokenPath = Join-Path $root 'token.txt'
$installedScript = Join-Path $root 'Install-WindowsMcp.ps1'
$windowsMcpVersion = '0.8.9'
$pythonVersion = '3.14'
$port = 8000

if ($Serve) {
    try {
        $binDir = Join-Path $root 'bin'
        $uv = Join-Path $binDir 'uv.exe'
        $server = Join-Path $binDir 'windows-mcp.exe'
        $env:UV_UNMANAGED_INSTALL = $binDir
        $env:UV_TOOL_BIN_DIR = $binDir
        $env:UV_TOOL_DIR = Join-Path $root 'tools'
        $env:UV_PYTHON_INSTALL_DIR = Join-Path $root 'python'
        $env:UV_CACHE_DIR = Join-Path $root 'uv-cache'
        $env:UV_PYTHON_PREFERENCE = 'only-managed'
        $env:WINDOWS_MCP_AUTH_KEY = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
        if ($env:WINDOWS_MCP_AUTH_KEY -cnotmatch '^[a-f0-9]{64}$') {
            throw 'The Windows-MCP token is missing or invalid.'
        }

        if (-not (Test-Path -LiteralPath $uv -PathType Leaf)) {
            New-Item -ItemType Directory -Path $binDir -Force | Out-Null
            $uvInstaller = Join-Path $root 'install-uv.ps1'
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -UseBasicParsing -Uri 'https://astral.sh/uv/install.ps1' -OutFile $uvInstaller
                & $uvInstaller
            } finally {
                Remove-Item -LiteralPath $uvInstaller -ErrorAction SilentlyContinue
            }
            if (-not (Test-Path -LiteralPath $uv -PathType Leaf)) {
                throw 'uv did not install successfully.'
            }
        }

        $versionMarker = Join-Path $root 'package-version.txt'
        $installedVersion = if (Test-Path -LiteralPath $versionMarker -PathType Leaf) {
            (Get-Content -LiteralPath $versionMarker -Raw).Trim()
        }
        if (($installedVersion -ne $windowsMcpVersion) -or (-not (Test-Path -LiteralPath $server -PathType Leaf))) {
            $installArgs = @('tool', 'install', '--python', $pythonVersion, "windows-mcp==$windowsMcpVersion")
            $install = Start-Process -FilePath $uv -ArgumentList $installArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $root 'install.stdout.log') -RedirectStandardError (Join-Path $root 'install.stderr.log')
            if (($install.ExitCode -ne 0) -or (-not (Test-Path -LiteralPath $server -PathType Leaf))) {
                throw "Windows-MCP installation failed with exit code $($install.ExitCode). See install.stderr.log."
            }
            Set-Content -LiteralPath $versionMarker -Value $windowsMcpVersion -Encoding Ascii
        }

        $serverArgs = @('serve', '--transport', 'streamable-http', '--host', '0.0.0.0', '--port', "$port")
        $process = Start-Process -FilePath $server -ArgumentList $serverArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $root 'server.stdout.log') -RedirectStandardError (Join-Path $root 'server.stderr.log')
        throw "Windows-MCP exited with code $($process.ExitCode). See server.stderr.log."
    } catch {
        Add-Content -LiteralPath (Join-Path $root 'task.log') -Value "$(Get-Date -Format s) $($_.Exception.Message)"
        exit 1
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this installer as Administrator from the Windows VM desktop.'
}

$localUser = Get-LocalUser -SID $identity.User
$accountName = "$env:COMPUTERNAME\$($localUser.Name)"
New-Item -ItemType Directory -Path $root -Force | Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not restrict permissions on the Windows-MCP installation folder.'
}

if (Test-Path -LiteralPath $tokenPath -PathType Leaf) {
    $token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
    if ($token -cnotmatch '^[a-f0-9]{64}$') {
        throw 'The existing token is invalid. Restore the original token.txt or remove it to generate a new one.'
    }
} else {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
    } finally {
        $random.Dispose()
    }
    $token = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    Set-Content -LiteralPath $tokenPath -Value $token -Encoding Ascii
}

$configPath = Join-Path $root 'opencode.windows-vm.json'
$config = @{
    mcp = @{
        servers = @{
            windows_vm = @{
                type = 'remote'
                url = 'http://127.0.0.1:8000/mcp/'
                oauth = $false
                headers = @{ Authorization = "Bearer $token" }
            }
        }
    }
}
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding Ascii
if ($PSCommandPath -ne $installedScript) {
    Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force
}

$ruleName = 'WindowsMcpVm-In-TCP'
if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $ruleName -DisplayName 'Windows-MCP for the VM' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port | Out-Null
}

try {
    $terminalService = Get-Service -Name 'TermService'
    Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    Enable-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-TCP'
    if ($terminalService.Status -ne 'Running') {
        Start-Service -Name 'TermService'
    }
} catch {
    Write-Warning "RDP could not be enabled on this Core11 guest. $($_.Exception.Message)"
}

$taskPrincipal = New-ScheduledTaskPrincipal -UserId $localUser.SID.Value -LogonType Interactive -RunLevel Highest
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $accountName
$taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 15 -RestartInterval (New-TimeSpan -Minutes 1)
$powershell = Join-Path $PSHOME 'powershell.exe'
$taskArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$installedScript"" -Serve"
$action = New-ScheduledTaskAction -Execute $powershell -Argument $taskArgs -WorkingDirectory $root

if ((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State -eq 'Running') {
    Stop-ScheduledTask -TaskName $taskName
}
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $taskSettings -Description 'Starts authenticated Windows-MCP in the signed-in Windows desktop.' -Force | Out-Null
try {
    Start-ScheduledTask -TaskName $taskName
} catch {
    Write-Warning 'The task is registered and will start at the next sign-in.'
}
Write-Output "Windows-MCP task registered for $accountName. Logs are in $root."
Write-Output "Copy the windows_vm entry from $configPath into OpenCode's mcp.servers on kloc."

if ($SkipAutologon) {
    Write-Output 'Automatic sign-in was skipped. The server starts when this user signs in.'
    exit
}

$winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$winlogon = Get-ItemProperty -LiteralPath $winlogonPath
if (($winlogon.AutoAdminLogon -eq '1') -and ($winlogon.DefaultUserName -eq $localUser.Name)) {
    Write-Output 'Automatic sign-in is already configured for this account.'
    exit
}

try {
    $autologonDir = Join-Path $root 'Autologon'
    $autologonZip = Join-Path $root 'Autologon.zip'
    $autologon = Join-Path $autologonDir 'Autologon64.exe'
    if (-not (Test-Path -LiteralPath $autologon -PathType Leaf)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://download.sysinternals.com/files/AutoLogon.zip' -OutFile $autologonZip
            Expand-Archive -LiteralPath $autologonZip -DestinationPath $autologonDir -Force
        } finally {
            Remove-Item -LiteralPath $autologonZip -ErrorAction SilentlyContinue
        }
    }
    $signature = Get-AuthenticodeSignature -FilePath $autologon
    if (($signature.Status -ne 'Valid') -or ($signature.SignerCertificate.Subject -notmatch 'CN=Microsoft Corporation')) {
        throw 'Microsoft Autologon could not be verified.'
    }
    Write-Output "In Microsoft Autologon, enter $($localUser.Name), domain $env:COMPUTERNAME, and the Windows account password. Click Enable."
    Start-Process -FilePath $autologon -Wait
    $winlogon = Get-ItemProperty -LiteralPath $winlogonPath
    if (($winlogon.AutoAdminLogon -eq '1') -and ($winlogon.DefaultUserName -eq $localUser.Name)) {
        Write-Output 'Automatic sign-in is configured. Reboot to test the startup task.'
    } else {
        Write-Warning 'Automatic sign-in was not confirmed. Sign in manually or enable Dockur AUTOLOGIN before a fresh install.'
    }
} catch {
    Write-Warning "Automatic sign-in setup failed. The MCP task will still run at sign-in. $($_.Exception.Message)"
}
