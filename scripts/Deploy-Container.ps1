param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactDirectory,

    [Parameter(Mandatory = $true)]
    [string]$DeployDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$ExpectedCommit,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedRepository,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string]$ExpectedRunId,

    [ValidateRange(1, 65535)]
    [int]$Port = 5090,

    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]+$')]
    [string]$ContainerName = 'toolcabinet-stand',

    [ValidateRange(1, 60)]
    [int]$HealthAttempts = 30
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-Docker {
    param([string[]]$Arguments)
    $output = & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker failed: $($Arguments[0]) $($Arguments[1])" }
    return $output
}

function Get-Container {
    param([string]$Name)
    $escapedName = [regex]::Escape($Name)
    $ids = @(Invoke-Docker -Arguments @('ps', '--all', '--filter', "name=^/$escapedName$", '--format', '{{.ID}}'))
    if ($ids.Count -eq 0) { return $null }
    $json = Invoke-Docker -Arguments @('container', 'inspect', $ids[0])
    return @((($json -join "`n") | ConvertFrom-Json))[0]
}

function Wait-Health {
    param([string]$Name, [string]$ImageId, [int]$HealthPort = $Port)
    $uri = "http://127.0.0.1:$HealthPort/api/v1/health"
    for ($attempt = 1; $attempt -le $HealthAttempts; $attempt++) {
        $container = Get-Container -Name $Name
        if ($null -eq $container -or -not $container.State.Running -or $container.Image -ne $ImageId) {
            throw 'The expected installed image is not running'
        }
        $response = $null
        try {
            $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 2 -MaximumRedirection 0
        } catch {
            if ($attempt -eq $HealthAttempts) { throw "Health request failed: $uri. $($_.Exception.Message)" }
        }
        if ($null -ne $response) {
            if ($response.StatusCode -ne 200 -or $response.Headers['Content-Type'] -notmatch '^application/json(?:;|$)') {
                throw 'Unexpected health status or content type'
            }
            $body = [string]$response.Content
            if (-not $body.TrimStart().StartsWith('{')) { throw 'Health response is not a JSON object' }
            $payload = $body | ConvertFrom-Json
            $properties = @($payload.PSObject.Properties)
            if ($properties.Count -ne 1 -or $properties[0].Name -cne 'status' -or $payload.status -cne 'ok') {
                throw "Unexpected health response: $body"
            }
            Write-Host "Installed API: HTTP 200 $body ($uri)"
            return
        }
        Start-Sleep -Seconds 1
    }
    throw 'Health check did not succeed'
}

# Validate the downloaded package before changing the installed version.
$artifactRoot = (Resolve-Path -LiteralPath $ArtifactDirectory).Path
$info = Get-Content -LiteralPath (Join-Path $artifactRoot 'build-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedImage = "toolcabinetapi:$ExpectedCommit"
if ($info.commit -cne $ExpectedCommit -or $info.repository -cne $ExpectedRepository -or
    [string]$info.runId -cne $ExpectedRunId -or $info.image -cne $expectedImage -or
    $info.platform -cne 'linux/amd64' -or $info.archive -cne 'toolcabinetapi.tar' -or
    $info.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or $info.imageId -notmatch '^sha256:[0-9a-f]{64}$') {
    throw 'Artifact metadata does not match this workflow run'
}
$archive = Join-Path $artifactRoot 'toolcabinetapi.tar'
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $info.sha256) {
    throw 'Artifact SHA256 mismatch'
}
if ((Invoke-Docker -Arguments @('info', '--format', '{{.OSType}}')) -ne 'linux') {
    throw 'Docker must use the Linux engine'
}

if (-not [System.IO.Path]::IsPathRooted($DeployDirectory)) { throw 'DeployDirectory must be an absolute path' }
$deployRoot = [System.IO.Path]::GetFullPath($DeployDirectory).TrimEnd('\', '/')
if ($deployRoot -eq [System.IO.Path]::GetPathRoot($deployRoot).TrimEnd('\', '/')) {
    throw 'DeployDirectory cannot be a filesystem root'
}
$previous = Get-Container -Name $ContainerName
if ($null -ne $previous -and
    ($previous.Config.Labels.'com.toolcabinet.managed' -ne 'true' -or
     $previous.Config.Labels.'com.toolcabinet.directory' -ne $deployRoot)) {
    throw "Container $ContainerName is not owned by this deployment directory"
}

$releaseDirectory = Join-Path $deployRoot "releases/$ExpectedCommit-$ExpectedRunId"
New-Item -ItemType Directory -Force $releaseDirectory | Out-Null
$installedArchive = Join-Path $releaseDirectory 'toolcabinetapi.tar'
Copy-Item -LiteralPath $archive -Destination $installedArchive -Force
Copy-Item -LiteralPath (Join-Path $artifactRoot 'build-info.json') -Destination $releaseDirectory -Force
if ((Get-FileHash -LiteralPath $installedArchive -Algorithm SHA256).Hash -ine $info.sha256) {
    throw 'Copied archive SHA256 mismatch'
}
Invoke-Docker -Arguments @('image', 'load', '--input', $installedArchive) | Write-Host
$imageJson = Invoke-Docker -Arguments @('image', 'inspect', $expectedImage)
$image = @((($imageJson -join "`n") | ConvertFrom-Json))[0]
if ($image.Id -ne $info.imageId -or $image.Os -ne 'linux' -or $image.Architecture -ne 'amd64' -or
    $image.Config.Labels.'org.opencontainers.image.revision' -cne $ExpectedCommit) {
    throw 'Loaded image identity, platform or source label does not match the artifact'
}

$backupName = "$ContainerName-previous-$([Guid]::NewGuid().ToString('N'))"
$previousRenamed = $false
$startAttempted = $false
try {
    if ($null -ne $previous) {
        if ($previous.State.Running) { Invoke-Docker -Arguments @('stop', '--time', '20', $ContainerName) | Out-Null }
        Invoke-Docker -Arguments @('rename', $ContainerName, $backupName) | Out-Null
        $previousRenamed = $true
    }
    $startAttempted = $true
    Invoke-Docker -Arguments @(
        'run', '--detach', '--pull', 'never', '--name', $ContainerName,
        '--restart', 'unless-stopped', '--publish', "127.0.0.1:${Port}:8080",
        '--env', 'ASPNETCORE_ENVIRONMENT=Production', '--env', 'ASPNETCORE_HTTP_PORTS=8080',
        '--label', 'com.toolcabinet.managed=true', '--label', "com.toolcabinet.directory=$deployRoot",
        $expectedImage
    ) | Out-Null
    Wait-Health -Name $ContainerName -ImageId $image.Id

    @{
        commit = $ExpectedCommit
        repository = $ExpectedRepository
        runId = $ExpectedRunId
        image = $expectedImage
        imageId = $image.Id
        container = $ContainerName
        port = $Port
        deployedAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $deployRoot 'current.json.tmp') -Encoding UTF8
    Move-Item -LiteralPath (Join-Path $deployRoot 'current.json.tmp') -Destination (Join-Path $deployRoot 'current.json') -Force
} catch {
    $deploymentError = $_
    try {
        $failed = Get-Container -Name $ContainerName
        if ($startAttempted -and $null -ne $failed -and $failed.Config.Labels.'com.toolcabinet.directory' -eq $deployRoot) {
            try {
                Invoke-Docker -Arguments @('logs', '--tail', '100', $ContainerName) |
                    Set-Content -LiteralPath (Join-Path $releaseDirectory 'failed-container.log') -Encoding UTF8
            } catch { Write-Warning 'Could not save failed container logs; continuing recovery' }
            Invoke-Docker -Arguments @('rm', '--force', $ContainerName) | Out-Null
        }
        if ($previousRenamed) {
            Invoke-Docker -Arguments @('rename', $backupName, $ContainerName) | Out-Null
            if ($previous.State.Running) {
                Invoke-Docker -Arguments @('start', $ContainerName) | Out-Null
                $previousPort = [int]$previous.HostConfig.PortBindings.'8080/tcp'[0].HostPort
                Wait-Health -Name $ContainerName -ImageId $previous.Image -HealthPort $previousPort
            }
            Write-Warning 'Previous container restored; this deployment is still FAILED'
        } elseif ($null -ne $previous -and $previous.State.Running) {
            Invoke-Docker -Arguments @('start', $ContainerName) | Out-Null
        }
    } catch {
        throw "Deployment failed: $($deploymentError.Exception.Message). Recovery also failed: $($_.Exception.Message)"
    }
    throw $deploymentError
}

if ($previousRenamed) {
    try { Invoke-Docker -Arguments @('rm', $backupName) | Out-Null }
    catch { Write-Warning "Deployment passed, but the old stopped container remains: $backupName" }
}
Write-Host "Deployment passed: $ExpectedCommit on port $Port"
