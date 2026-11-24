param(
    [Parameter(Mandatory = $true)]
    [string]$Image,

    [ValidateRange(1, 60)]
    [int]$Attempts = 30,

    [ValidatePattern('^/')]
    [string]$HealthPath = '/api/v1/health'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$containerName = 'toolcabinet-check-' + [Guid]::NewGuid().ToString('N')

try {
    # Docker выбирает свободный порт; существующий Compose-контейнер не затрагивается.
    $containerId = docker run --detach --pull never --name $containerName --publish '127.0.0.1::8080' $Image
    if ($LASTEXITCODE -ne 0) { throw "Cannot start image $Image" }

    $portMapping = docker port $containerName 8080/tcp
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read container port' }
    $port = ([string]$portMapping).Trim().Split(':')[-1]
    $uri = "http://127.0.0.1:$port$HealthPath"

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $running = docker inspect --format '{{.State.Running}}' $containerName
        if ($LASTEXITCODE -ne 0 -or $running -ne 'true') {
            throw 'Container stopped before the health check succeeded'
        }

        $response = $null
        try {
            $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 2 -MaximumRedirection 0
        } catch {
            # Во время запуска Kestrel ещё может не принимать соединения.
            if ($attempt -eq $Attempts) { throw "Health request failed: $uri. $($_.Exception.Message)" }
        }

        if ($null -ne $response) {
            if ($response.StatusCode -ne 200) { throw "Unexpected HTTP status: $($response.StatusCode)" }
            if ($response.Headers['Content-Type'] -notmatch '^application/json(?:;|$)') {
                throw 'Health response is not application/json'
            }
            $body = [string]$response.Content
            if (-not $body.TrimStart().StartsWith('{')) { throw 'Health response must be a JSON object' }
            $payload = $body | ConvertFrom-Json
            $properties = @($payload.PSObject.Properties)
            if ($properties.Count -ne 1 -or $properties[0].Name -cne 'status' -or $payload.status -cne 'ok') {
                throw "Unexpected health JSON: $body"
            }
            Write-Host "Container health passed: HTTP 200 $body ($uri)"
            return
        }

        Start-Sleep -Seconds 1
    }
    throw 'Container health check did not succeed'
} catch {
    docker logs --tail 100 $containerName
    throw
} finally {
    docker rm --force $containerName | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not remove temporary container $containerName" }
}
