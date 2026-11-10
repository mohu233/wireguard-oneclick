Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $bundleRoot 'deploy.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('PowerShell syntax errors: ' + ($parseErrors.Message -join '; ')) }
. (Join-Path $bundleRoot 'deploy.ps1')

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert-True $thrown $Message
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('wg-deploy-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporaryRoot)
$utf8 = New-Object Text.UTF8Encoding($false)
$configPath = Join-Path $temporaryRoot 'server.env'
try {
    [IO.File]::WriteAllText($configPath, "SSH_HOST=203.0.113.10`nENDPOINT=example.com`nWG_PORT=51821`n", $utf8)
    $settings = Read-ServerSettings $configPath
    Assert-True ($settings.ENDPOINT -eq 'example.com') 'Endpoint parsing failed'
    Assert-True ($settings.SSH_PORT -eq '22') 'Default SSH port failed'
    $payload = New-RemotePayload -Settings $settings -BundleRoot $bundleRoot
    Assert-True ($payload.Contains('bash ./deploy.sh --export-stdout ./server.env')) 'Wrong deploy command'
    Assert-True (-not $payload.Contains("`r")) 'Remote payload must use LF'
    Assert-True ($payload.Contains('trap')) 'Missing remote temporary directory cleanup'
    $sourceParts = [regex]::Matches($payload, "(?m)^base64 -d.*?__WG_SOURCE__'\n([A-Za-z0-9+/=]+)\n__WG_SOURCE__$")
    Assert-True ($sourceParts.Count -eq 2) 'Must send exactly two shipped source files'
    foreach ($part in $sourceParts) {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.Groups[1].Value))
        Assert-True ($decoded.StartsWith('#!')) 'Remote source encoding broken'
    }
    $checkPayload = New-RemotePayload -Settings $settings -BundleRoot $bundleRoot -Mode check
    Assert-True ($checkPayload.Contains('bash ./deploy.sh --check ./server.env')) 'Read-only check mode broken'
    $exportPayload = New-RemotePayload -Settings $settings -BundleRoot $bundleRoot -Mode export
    Assert-True ($exportPayload.Contains('--export --export-stdout')) 'Export mode broken'

    $invalidConfigs = @(
        "SSH_HOST=203.0.113.10;echo injected`n",
        "SSH_HOST=`$(echo injected)`n",
        "SSH_HOST=-oProxyCommand=evil`n",
        "SSH_HOST=203.0.113.10`nSSH_HOST=203.0.113.11`n",
        "SSH_HOST=203.0.113.10`nPASSWORD=never-store-this`n",
        "SSH_HOST=203.0.113.10`nWG_PORT=65536`n",
        "SSH_HOST=203.0.113.10`nDNS=1.1.1.1;bad`n",
        "SSH_HOST=203.0.113.10`nVPN_SUBNET=192.9.1.0/24`n"
    )
    foreach ($invalidConfig in $invalidConfigs) {
        [IO.File]::WriteAllText($configPath, $invalidConfig, $utf8)
        Assert-Throws { Read-ServerSettings $configPath } 'Unsafe/invalid configuration was accepted'
    }
    $testKeys = @([Convert]::ToBase64String([byte[]](1..32)), [Convert]::ToBase64String([byte[]](33..64)))
    $profiles = @{}
    $index = 0
    foreach ($fileName in @('wg-router.conf', 'wg-test.conf')) {
        $content = "[Interface]`nPrivateKey = $($testKeys[$index])`nAddress = 10.66.66.$($index + 2)/32`n`n[Peer]`nPublicKey = $($testKeys[0])`nAllowedIPs = 0.0.0.0/0`nEndpoint = example.com:51821`n"
        $line = '__WG_PROFILE__' + $fileName + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
        $decodedProfile = ConvertFrom-ProfileLine $line
        $profiles[$decodedProfile.Name] = $decodedProfile.Content
        Assert-True ($decodedProfile.Content -eq $content) 'Profile protocol changed content'
        $index++
    }
    Test-ProfilePair -Profiles $profiles -Settings $settings
    Assert-Throws { ConvertFrom-ProfileLine '__WG_PROFILE__../escape.conf:QQ==' } 'Unsafe profile filename was accepted'
    $missingProfile = @{'wg-router.conf' = $profiles['wg-router.conf']}
    Assert-Throws { Test-ProfilePair -Profiles $missingProfile -Settings $settings } 'Partial profile pair was accepted'
    $profiles['wg-test.conf'] = $profiles['wg-test.conf'].Replace($testKeys[1], $testKeys[0])
    Assert-Throws { Test-ProfilePair -Profiles $profiles -Settings $settings } 'Shared client key was accepted'
    $privateOutput = Join-Path $temporaryRoot 'output'
    Protect-OutputDirectory $privateOutput
    Assert-True (Get-Acl -LiteralPath $privateOutput).AreAccessRulesProtected 'Output permissions are inherited'
    # Exercise the actual child-process transport and private file writing with
    # an executable fixture, without contacting any SSH server.
    $fixtureBin = Join-Path $temporaryRoot 'bin'
    [void][IO.Directory]::CreateDirectory($fixtureBin)
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows offline transport test requires the .NET Framework C# compiler.' }
    & $compiler /nologo /target:exe ('/out:' + (Join-Path $fixtureBin 'ssh.exe')) (Join-Path $PSScriptRoot 'ssh_fixture.cs')
    Assert-True ($LASTEXITCODE -eq 0) 'SSH fixture compilation failed'
    [IO.File]::WriteAllText($configPath, "SSH_HOST=203.0.113.10`nENDPOINT=example.com`nWG_PORT=51821`n", $utf8)
    $oldPath = $env:PATH
    $oldFailureMode = [Environment]::GetEnvironmentVariable('WG_FIXTURE_FAIL')
    try {
        $env:PATH = $fixtureBin + [IO.Path]::PathSeparator + $oldPath
        $deployTranscript = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bundleRoot 'deploy.ps1') -ServerFolder $temporaryRoot 2>&1 | Out-String)
        Assert-True ($LASTEXITCODE -eq 0) ('Offline transport failed: ' + $deployTranscript)
        Assert-True (-not $deployTranscript.Contains('__WG_PROFILE__')) 'Private profile markers leaked into console output'
        Assert-True (-not $deployTranscript.Contains($testKeys[0])) 'Client key leaked into console output'
        $routerOutput = Join-Path $privateOutput 'wg-router.conf'
        $testOutput = Join-Path $privateOutput 'wg-test.conf'
        Assert-True (Test-Path -LiteralPath $routerOutput) 'Router profile was not saved'
        Assert-True (Test-Path -LiteralPath $testOutput) 'Test profile was not saved'
        $beforeFailure = [IO.File]::ReadAllText($routerOutput)
        $env:WG_FIXTURE_FAIL = '1'
        $failureTranscript = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bundleRoot 'deploy.ps1') -ServerFolder $temporaryRoot 2>&1 | Out-String)
        Assert-True ($LASTEXITCODE -ne 0) 'Failed SSH deployment was reported as success'
        Assert-True ([IO.File]::ReadAllText($routerOutput) -eq $beforeFailure) 'Failed deployment overwrote a local profile'
        Assert-True (-not $failureTranscript.Contains('__WG_PROFILE__')) 'Failed deployment exposed profile markers'
    } finally {
        $env:PATH = $oldPath
        [Environment]::SetEnvironmentVariable('WG_FIXTURE_FAIL', $oldFailureMode)
    }
    Write-Host 'Windows tests passed: parser, validation, SSH payload/protocol, ACL, file export, and failed-deployment preservation.'
} finally {
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTemporaryRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedTemporaryRoot) -notlike 'wg-deploy-test-*') { throw 'Refusing unsafe temporary cleanup' }
    Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
}
