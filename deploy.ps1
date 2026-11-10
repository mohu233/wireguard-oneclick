[CmdletBinding()]
param(
    [string]$ServerFolder = '',
    [switch]$CheckOnly,
    [switch]$ExportOnly,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-ServerSettings {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Interactive)
    $settings = [ordered]@{
        SSH_HOST = ''; SSH_PORT = '22'; SSH_USER = 'root'; SSH_IDENTITY_FILE = ''
        ENDPOINT = ''; WG_PORT = '51820'; VPN_SUBNET = '10.66.66.0/24'
        DNS = '1.1.1.1,9.9.9.9'; MTU = '1420'; WAN_INTERFACE = 'auto'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到服务器资料文件：$Path"
    }
    $seen = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        $text = $line.Trim().TrimStart([char]0xFEFF)
        if ($text.Length -eq 0 -or $text.StartsWith('#')) { continue }
        if ($text -notmatch '^([A-Z_]+)=(.*)$') { throw "资料格式应为 KEY=VALUE：$text" }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if (-not $settings.Contains($key)) { throw "不支持的资料字段：$key" }
        if ($seen.ContainsKey($key)) { throw "资料字段重复：$key" }
        $seen[$key] = $true
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($value.Contains("`r") -or $value.Contains("`n")) { throw "资料字段不能换行：$key" }
        $settings[$key] = $value
    }
    if ([string]::IsNullOrWhiteSpace($settings.SSH_HOST)) {
        if (-not $Interactive) { throw '请填写 SSH_HOST（新服务器 IP 或域名）。' }
        $settings.SSH_HOST = (Read-Host '请输入新服务器 IP 或域名').Trim()
    }
    if ([string]::IsNullOrWhiteSpace($settings.ENDPOINT)) { $settings.ENDPOINT = $settings.SSH_HOST }
    foreach ($key in @('SSH_HOST', 'ENDPOINT')) {
        if ($settings[$key] -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$') {
            throw "$key 必须是 IPv4 地址或域名，不能带协议、端口、空格或命令。"
        }
        $hostType = [Uri]::CheckHostName($settings[$key])
        if ($hostType -eq [UriHostNameType]::Unknown -or $hostType -eq [UriHostNameType]::IPv6) {
            throw "$key 不是有效的 IPv4 地址或域名。"
        }
        if ($settings[$key] -match '^[0-9.]+$' -and $hostType -ne [UriHostNameType]::IPv4) {
            throw "$key 不是有效的 IPv4 地址。"
        }
    }
    if ($settings.SSH_USER -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw 'SSH_USER 格式无效。' }
    foreach ($key in @('SSH_PORT', 'WG_PORT')) {
        if ($settings[$key] -notmatch '^\d{1,5}$' -or [int]$settings[$key] -lt 1 -or
            [int]$settings[$key] -gt 65535) { throw "$key 必须为 1～65535。" }
        $settings[$key] = ([int]$settings[$key]).ToString()
    }
    if ($settings.MTU -notmatch '^\d{3,4}$' -or [int]$settings.MTU -lt 1280 -or
        [int]$settings.MTU -gt 1420) { throw 'MTU 必须为 1280～1420。' }
    if ($settings.VPN_SUBNET -notmatch '^(10|172|192)\.\d{1,3}\.\d{1,3}\.0/24$') {
        throw 'VPN_SUBNET 请填写私有 IPv4 /24 网段，例如 10.66.66.0/24。'
    }
    $networkAddress = $settings.VPN_SUBNET.Split('/')[0]
    if ([Uri]::CheckHostName($networkAddress) -ne [UriHostNameType]::IPv4) {
        throw 'VPN_SUBNET 的 IPv4 地址无效。'
    }
    $octets = $networkAddress.Split('.')
    if (($octets[0] -eq '172' -and ([int]$octets[1] -lt 16 -or [int]$octets[1] -gt 31)) -or
        ($octets[0] -eq '192' -and $octets[1] -ne '168')) { throw 'VPN_SUBNET 必须为私有地址段。' }
    $dnsValues = $settings.DNS.Split(',')
    if ($dnsValues.Count -lt 1 -or $dnsValues.Count -gt 3) { throw 'DNS 填写 1～3 个逗号分隔的 IPv4 地址。' }
    foreach ($dnsAddress in $dnsValues) {
        if ([Uri]::CheckHostName($dnsAddress) -ne [UriHostNameType]::IPv4) { throw 'DNS 必须为 IPv4 地址。' }
    }
    if ($settings.WAN_INTERFACE -ne 'auto' -and $settings.WAN_INTERFACE -notmatch '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}$') {
        throw 'WAN_INTERFACE 应为 auto 或有效网卡名。'
    }
    return $settings
}

function New-RemotePayload {
    param([Parameter(Mandatory = $true)]$Settings,
          [Parameter(Mandatory = $true)][string]$BundleRoot,
          [ValidateSet('deploy', 'check', 'export')][string]$Mode = 'deploy')
    $payload = New-Object Text.StringBuilder
    [void]$payload.Append(@'
set -eu
umask 077
command -v bash >/dev/null 2>&1 || { echo 'ERROR: server needs bash' >&2; exit 2; }
taskdir=$(mktemp -d /tmp/office-wg-upload.XXXXXXXX)
trap 'rm -rf -- "$taskdir"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
mkdir -p "$taskdir/lib"

'@)
    # Only explicitly shipped source files are sent. Existing profiles and local
    # server folders are never recursively uploaded.
    foreach ($relativePath in @('deploy.sh', 'lib/install-runtime.sh')) {
        $filePath = Join-Path $BundleRoot $relativePath
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { throw "部署包缺少文件：$relativePath" }
        $sourceText = [IO.File]::ReadAllText($filePath, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sourceText))
        [void]$payload.Append("base64 -d >`"`$taskdir/$relativePath`" <<'__WG_SOURCE__'`n$encoded`n__WG_SOURCE__`n")
    }
    $configLines = foreach ($key in @('ENDPOINT', 'WG_PORT', 'VPN_SUBNET', 'DNS', 'MTU', 'WAN_INTERFACE')) {
        $key + '=' + $Settings[$key]
    }
    $configData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($configLines -join "`n") + "`n"))
    [void]$payload.Append("base64 -d >`"`$taskdir/server.env`" <<'__WG_SETTINGS__'`n$configData`n__WG_SETTINGS__`n")
    [void]$payload.Append("cd `"`$taskdir`"`n")
    $modeArgs = switch ($Mode) {
        'check' { '--check' }
        'export' { '--export --export-stdout' }
        default { '--export-stdout' }
    }
    [void]$payload.Append("bash ./deploy.sh $modeArgs ./server.env`n")
    # Git checkouts on Windows may use CRLF in the literal here-string above.
    # Normalize the entire transport, including its shell wrapper, before SSH.
    return $payload.ToString().Replace("`r`n", "`n")
}

function ConvertFrom-ProfileLine {
    param([string]$Line)
    if (-not $Line.StartsWith('__WG_PROFILE__')) { return $null }
    if ($Line -notmatch '^__WG_PROFILE__(wg-router\.conf|wg-test\.conf):([A-Za-z0-9+/=]+)$') {
        throw '服务器返回了无效的配置文件数据。'
    }
    $name = $Matches[1]
    $data = [Convert]::FromBase64String($Matches[2])
    if ($data.Length -gt 8192) { throw '服务器返回的配置文件异常过大。' }
    $content = [Text.Encoding]::UTF8.GetString($data).Replace("`r`n", "`n")
    if ($content -notmatch '(?m)^\[Interface\]$' -or $content -notmatch '(?m)^\[Peer\]$' -or
        $content -notmatch '(?m)^PrivateKey\s*=\s*[A-Za-z0-9+/]{43}=\s*$') {
        throw "服务器返回的 $name 不是有效的 WireGuard 配置。"
    }
    return [PSCustomObject]@{ Name = $name; Content = $content }
}

function Test-ProfilePair {
    param([Parameter(Mandatory = $true)]$Profiles, [Parameter(Mandatory = $true)]$Settings)
    if ($Profiles.Count -ne 2 -or -not $Profiles.ContainsKey('wg-router.conf') -or
        -not $Profiles.ContainsKey('wg-test.conf')) { throw '部署未返回完整的两个客户端配置，未保存文件。' }
    $prefix = $Settings.VPN_SUBNET -replace '\.0/24$', ''
    $privateKeys = @()
    foreach ($item in @(@('wg-router.conf', '2'), @('wg-test.conf', '3'))) {
        $profileContent = $Profiles[$item[0]]
        $address = [regex]::Escape($prefix + '.' + $item[1] + '/32')
        $endpoint = [regex]::Escape($Settings.ENDPOINT + ':' + $Settings.WG_PORT)
        if ($profileContent -notmatch "(?m)^Address\s*=\s*$address\s*$" -or
            $profileContent -notmatch "(?m)^Endpoint\s*=\s*$endpoint\s*$" -or
            $profileContent -notmatch '(?m)^AllowedIPs\s*=\s*0\.0\.0\.0/0\s*$') {
            throw "返回的 $($item[0]) 与本次服务器资料不一致，未保存文件。"
        }
        [void]($profileContent -match '(?m)^PrivateKey\s*=\s*(\S+)\s*$')
        $privateKeys += $Matches[1]
    }
    if ($privateKeys[0] -eq $privateKeys[1]) { throw '两个客户端使用了相同私钥，未保存文件。' }
}

function Protect-OutputDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    [void][IO.Directory]::CreateDirectory($Path)
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $Path /inheritance:r /grant:r ('*' + $userSid + ':(OI)(CI)F') '*S-1-5-18:(OI)(CI)F' /q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '无法保护输出目录权限，停止保存私钥。请使用 NTFS 本地目录。' }
}

function Invoke-WgDeploy {
    param([string]$Folder, [switch]$Check, [switch]$Export, [switch]$Validate)
    if ($Check -and $Export) { throw 'CheckOnly 和 ExportOnly 不能同时使用。' }
    if ([string]::IsNullOrWhiteSpace($Folder)) { $Folder = $PSScriptRoot }
    $Folder = (Resolve-Path -LiteralPath $Folder).Path
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw '请拖入包含 server.env 的文件夹。' }
    $configFile = Join-Path $Folder 'server.env'
    $settings = Read-ServerSettings -Path $configFile -Interactive:(-not $Validate)
    $mode = if ($Check) { 'check' } elseif ($Export) { 'export' } else { 'deploy' }
    $payload = New-RemotePayload -Settings $settings -BundleRoot $PSScriptRoot -Mode $mode
    Write-Host ('目标服务器：{0}@{1}:{2}' -f $settings.SSH_USER, $settings.SSH_HOST, $settings.SSH_PORT)
    Write-Host ('WireGuard 接入：{0}:{1}/UDP' -f $settings.ENDPOINT, $settings.WG_PORT)
    if ($Validate) { Write-Host '资料和部署包验证通过；未连接服务器。'; return }
    $sshCommand = Get-Command ssh.exe -ErrorAction Stop
    $sshArgs = @('-T', '-p', $settings.SSH_PORT, '-o', 'ConnectTimeout=15',
        '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=6', '-o', 'StrictHostKeyChecking=ask')
    if ($settings.SSH_IDENTITY_FILE.Length -gt 0) {
        $identityFile = $settings.SSH_IDENTITY_FILE
        if (-not [IO.Path]::IsPathRooted($identityFile)) { $identityFile = Join-Path $Folder $identityFile }
        $identityFile = (Resolve-Path -LiteralPath $identityFile).Path
        if (-not (Test-Path -LiteralPath $identityFile -PathType Leaf)) { throw 'SSH 私钥文件无效。' }
        $sshArgs += @('-i', $identityFile)
    }
    $sshArgs += @($settings.SSH_USER + '@' + $settings.SSH_HOST, 'sh -s')
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $sshCommand.Source
    # All arguments are either validated data or literal options. Windows paths
    # are quoted; ProcessStartInfo launches ssh directly without cmd.exe.
    $startInfo.Arguments = (($sshArgs | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $false
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $profiles = @{}
    try {
        Write-Host '首次连接请核对 SSH 指纹；随后输入 root 密码（输入时不显示）。'
        [void]$process.Start()
        $process.StandardInput.Write($payload)
        $process.StandardInput.Close()
        while ($null -ne ($line = $process.StandardOutput.ReadLine())) {
            $profileResult = ConvertFrom-ProfileLine -Line $line
            if ($null -ne $profileResult) {
                if ($profiles.ContainsKey($profileResult.Name)) { throw '服务器重复返回配置，停止保存。' }
                $profiles[$profileResult.Name] = $profileResult.Content
            } elseif ($line -notmatch '(?i)privatekey|presharedkey') { Write-Host $line }
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "SSH 或服务器部署失败（退出码 $($process.ExitCode)）；未覆盖本地配置。" }
        if ($Check) { Write-Host '服务器预检完成，尚未部署。'; return }
        Test-ProfilePair -Profiles $profiles -Settings $settings
        $outputDirectory = Join-Path $Folder 'output'
        Protect-OutputDirectory -Path $outputDirectory
        $encoding = New-Object Text.UTF8Encoding($false)
        foreach ($name in @('wg-router.conf', 'wg-test.conf')) {
            $target = Join-Path $outputDirectory $name
            $temporary = Join-Path $outputDirectory ('.' + $name + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [IO.File]::WriteAllText($temporary, $profiles[$name], $encoding)
                Move-Item -LiteralPath $temporary -Destination $target -Force
            } finally {
                if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
            }
        }
        Write-Host ''
        Write-Host '完成，两份独立配置已保存：' -ForegroundColor Green
        Write-Host (Join-Path $outputDirectory 'wg-router.conf')
        Write-Host (Join-Path $outputDirectory 'wg-test.conf')
        Write-Host '软路由导入 wg-router.conf；电脑或手机测试使用 wg-test.conf。'
    } finally {
        $profiles.Clear()
        $process.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-WgDeploy -Folder $ServerFolder -Check:$CheckOnly -Export:$ExportOnly -Validate:$ValidateOnly
    } catch {
        Write-Host ('错误：' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
