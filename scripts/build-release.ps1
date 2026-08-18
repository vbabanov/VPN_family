[CmdletBinding()]
param(
    [ValidateSet('arm64', 'armv7', 'universal', 'all')]
    [string]$Target = 'arm64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$keyProperties = Join-Path $repositoryRoot 'android/key.properties'

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter is not available in PATH.'
}

if (-not (Test-Path -LiteralPath $keyProperties)) {
    throw 'Create android/key.properties from android/key.properties.example first.'
}

function Invoke-Flutter {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & flutter @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "flutter $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

Push-Location $repositoryRoot
try {
    Invoke-Flutter @('pub', 'get')
    Invoke-Flutter @('analyze')

    switch ($Target) {
        'arm64' {
            Invoke-Flutter @('build', 'apk', '--release', '--target-platform', 'android-arm64', '--split-per-abi')
        }
        'armv7' {
            Invoke-Flutter @('build', 'apk', '--release', '--target-platform', 'android-arm', '--split-per-abi')
        }
        'universal' {
            Invoke-Flutter @('build', 'apk', '--release')
        }
        'all' {
            Invoke-Flutter @('build', 'apk', '--release', '--split-per-abi')
        }
    }

    Get-ChildItem 'build/app/outputs/flutter-apk' -Filter '*release.apk' |
        Sort-Object Name |
        Select-Object Name, @{Name = 'MiB'; Expression = { [math]::Round($_.Length / 1MB, 2) } }, FullName
}
finally {
    Pop-Location
}
