#requires -Version 5.1
<#
.SYNOPSIS
    Publishes exactly 2 pending Instagram feed posts from the Codeonto lookup CSV.

.DESCRIPTION
    Repository structure is kept flat:
      Codeonto_Instagram_Lookup.csv
      Day1Photo1.png
      Day1Photo2.png
      ...

    Workflow:
      1. Pull latest GitHub changes.
      2. Read the lookup CSV.
      3. Select the earliest Day that has unpublished posts.
      4. Process exactly 2 posts from that Day, in Post order.
      5. Ensure the image is a JPEG. PNG files are converted to JPEG in the
         same repository root and the CSV Photo_File is updated.
      6. Verify the public GitHub raw URL.
      7. Create an Instagram media container.
      8. Poll until the container is FINISHED.
      9. Publish the container.
     10. Only after successful publication, update Published, Instagram_Media_ID
         and Published_At, then commit/push the CSV to GitHub.

    IMPORTANT:
      - Do NOT put the Instagram access token in this file or in GitHub.
      - Set IG_ACCESS_TOKEN as an environment variable.
      - This script uses the Instagram Login API path: graph.instagram.com.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [int]$PostsPerRun = 2,
    [int]$PollSeconds = 10,
    [int]$MaxPolls = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Configuration
# -----------------------------
$RepoPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$CsvName = "Codeonto_Instagram_Lookup.csv"
$CsvPath = Join-Path $RepoPath $CsvName

# Instagram Login API
$ApiVersion = if ($env:IG_API_VERSION) { $env:IG_API_VERSION } else { "v26.0" }
$InstagramUserId = if ($env:IG_USER_ID) {
    $env:IG_USER_ID
} else {
    "17841492927456129"
}

$AccessToken = $env:IG_ACCESS_TOKEN

$RawBaseUrl = "https://raw.githubusercontent.com/sourabh1119/Instagram-Photos/main"

# -----------------------------
# Helpers
# -----------------------------
function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Throw-ApiError {
    param(
        [string]$Operation,
        $Response
    )

    $details = $Response | ConvertTo-Json -Depth 10 -Compress
    throw "$Operation failed. API response: $details"
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    Push-Location $RepoPath
    try {
        $output = & git @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Git command failed: git $($Arguments -join ' ')`n$($output -join "`n")"
        }
        return $output
    }
    finally {
        Pop-Location
    }
}

function Commit-And-Push {
    param(
        [string]$Message
    )

    Write-Step "Committing repository update"

    Push-Location $RepoPath
    try {
        & git add -- $CsvName
        if ($LASTEXITCODE -ne 0) {
            throw "git add failed."
        }

        # Add any newly generated JPEGs.
        & git add -- '*.jpg' '*.jpeg'
        if ($LASTEXITCODE -ne 0) {
            # Git returns non-zero when no matching files exist; that is okay.
        }

        $status = & git status --porcelain
        if (-not $status) {
            Write-Host "No Git changes to commit."
            return
        }

        & git commit -m $Message
        if ($LASTEXITCODE -ne 0) {
            throw "git commit failed."
        }

        & git push origin main
        if ($LASTEXITCODE -ne 0) {
            throw "git push failed. Check GitHub authentication and repository permissions."
        }
    }
    finally {
        Pop-Location
    }
}

function Convert-ImageToJpeg {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    Add-Type -AssemblyName System.Drawing

    $image = $null
    $bitmap = $null
    $graphics = $null
    $encoder = $null
    $encoderParams = $null

    try {
        $image = [System.Drawing.Image]::FromFile($SourcePath)

        # Create an RGB bitmap. This also gives JPEG a safe background
        # when the PNG has transparency.
        $bitmap = New-Object System.Drawing.Bitmap(
            $image.Width,
            $image.Height,
            [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
        )

        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.DrawImage(
            $image,
            0,
            0,
            $image.Width,
            $image.Height
        )

        $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
            Where-Object { $_.MimeType -eq "image/jpeg" } |
            Select-Object -First 1

        $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
            [System.Drawing.Imaging.Encoder]::Quality,
            [long]95
        )

        $bitmap.Save(
            $DestinationPath,
            $jpegCodec,
            $encoderParams
        )
    }
    finally {
        if ($encoderParams) { $encoderParams.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($image) { $image.Dispose() }
    }
}

function Ensure-Jpeg {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Row
    )

    $fileName = [string]$Row.Photo_File
    $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()

    if ($extension -eq ".jpg" -or $extension -eq ".jpeg") {
        return $fileName
    }

    if ($extension -ne ".png") {
        throw "Unsupported image format '$extension' for '$fileName'. Use JPEG images."
    }

    $sourcePath = Join-Path $RepoPath $fileName
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Image not found in repository: $sourcePath"
    }

    $destinationName = [System.IO.Path]::GetFileNameWithoutExtension($fileName) + ".jpg"
    $destinationPath = Join-Path $RepoPath $destinationName

    if (-not (Test-Path -LiteralPath $destinationPath)) {
        Write-Step "Converting PNG to JPEG: $fileName -> $destinationName"
        Convert-ImageToJpeg -SourcePath $sourcePath -DestinationPath $destinationPath
    }
    else {
        Write-Host "JPEG already exists: $destinationName"
    }

    return $destinationName
}

function Get-RawImageUrl {
    param(
        [Parameter(Mandatory)]
        [string]$FileName
    )

    $encoded = [System.Uri]::EscapeDataString($FileName)
    return "$RawBaseUrl/$encoded"
}

function Test-PublicImageUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    Write-Host "Checking public image URL:"
    Write-Host $Url

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing
        if ($response.StatusCode -ne 200) {
            throw "HTTP status $($response.StatusCode)"
        }

        $contentType = [string]$response.Headers["Content-Type"]
        Write-Host "HTTP $($response.StatusCode) / $contentType"

        if ($contentType -and $contentType -notmatch "image/jpeg") {
            Write-Warning "GitHub returned Content-Type '$contentType'. Instagram publishing expects JPEG for feed image publishing."
        }
    }
    catch {
        throw "Public image URL is not reachable: $Url`n$($_.Exception.Message)"
    }
}

function New-InstagramContainer {
    param(
        [Parameter(Mandatory)]
        [string]$ImageUrl,

        [Parameter(Mandatory)]
        [string]$Caption
    )

    $uri = "https://graph.instagram.com/$ApiVersion/$InstagramUserId/media"

    $body = @{
        image_url   = $ImageUrl
        caption     = $Caption
        access_token = $AccessToken
    }

    try {
        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method Post `
            -Body $body `
            -ContentType "application/x-www-form-urlencoded"
    }
    catch {
        throw "Instagram container creation failed: $($_.Exception.Message)"
    }

    if (-not $response.id) {
        Throw-ApiError -Operation "Instagram container creation" -Response $response
    }

    return [string]$response.id
}

function Wait-ForInstagramContainer {
    param(
        [Parameter(Mandatory)]
        [string]$ContainerId
    )

    $uri = "https://graph.instagram.com/$ApiVersion/$ContainerId"

    for ($i = 1; $i -le $MaxPolls; $i++) {
        Start-Sleep -Seconds $PollSeconds

        try {
            $response = Invoke-RestMethod `
                -Uri $uri `
                -Method Get `
                -Body @{
                    fields = "status_code,status"
                    access_token = $AccessToken
                }
        }
        catch {
            throw "Unable to check Instagram container status: $($_.Exception.Message)"
        }

        $status = [string]$response.status_code
        Write-Host "Container $ContainerId status: $status"

        switch ($status) {
            "FINISHED" { return $true }
            "PUBLISHED" { return $true }
            "ERROR" {
                $detail = if ($response.status) { $response.status } else { "No additional status supplied." }
                throw "Instagram container entered ERROR state: $detail"
            }
            "EXPIRED" {
                throw "Instagram container expired before publication."
            }
        }
    }

    throw "Instagram container did not reach FINISHED within the configured polling window."
}

function Publish-InstagramContainer {
    param(
        [Parameter(Mandatory)]
        [string]$ContainerId
    )

    $uri = "https://graph.instagram.com/$ApiVersion/$InstagramUserId/media_publish"

    try {
        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method Post `
            -Body @{
                creation_id = $ContainerId
                access_token = $AccessToken
            } `
            -ContentType "application/x-www-form-urlencoded"
    }
    catch {
        throw "Instagram publish failed: $($_.Exception.Message)"
    }

    if (-not $response.id) {
        Throw-ApiError -Operation "Instagram publication" -Response $response
    }

    return [string]$response.id
}

function Save-Csv {
    param(
        [Parameter(Mandatory)]
        [array]$Rows
    )

    $Rows | Export-Csv `
        -LiteralPath $CsvPath `
        -NoTypeInformation `
        -Encoding UTF8
}

# -----------------------------
# Pre-flight
# -----------------------------
Write-Step "Instagram Publisher starting"

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

if (-not $DryRun -and [string]::IsNullOrWhiteSpace($AccessToken)) {
    throw "IG_ACCESS_TOKEN environment variable is not set."
}

if ($PostsPerRun -lt 1 -or $PostsPerRun -gt 2) {
    throw "PostsPerRun must be 1 or 2 for this campaign."
}

Write-Host "Repository : $RepoPath"
Write-Host "CSV        : $CsvName"
Write-Host "Instagram  : $InstagramUserId"
Write-Host "API        : $ApiVersion"
Write-Host "Dry Run    : $DryRun"
Write-Host "Posts/run  : $PostsPerRun"

# Keep local checkout current before reading/updating the queue.
if (-not $DryRun) {
    Write-Step "Pulling latest GitHub changes"
    Invoke-Git -Arguments @("pull", "--ff-only", "origin", "main") | Out-Host
}

# -----------------------------
# Load queue
# -----------------------------
$rows = @(Import-Csv -LiteralPath $CsvPath)

if ($rows.Count -eq 0) {
    throw "CSV contains no rows."
}

# Normalize Published values.
foreach ($row in $rows) {
    if ([string]::IsNullOrWhiteSpace([string]$row.Published)) {
        $row.Published = "False"
    }
}

$pending = @(
    $rows |
    Where-Object {
        ([string]$_.Published).ToLowerInvariant() -ne "true"
    } |
    Sort-Object `
        @{ Expression = { [int]$_.Day }; Ascending = $true }, `
        @{ Expression = { [int]$_.Post }; Ascending = $true }
)

if ($pending.Count -eq 0) {
    Write-Host "No unpublished posts remain. Campaign complete." -ForegroundColor Green
    exit 0
}

$nextDay = [int]$pending[0].Day

$todayRows = @(
    $pending |
    Where-Object { [int]$_.Day -eq $nextDay } |
    Sort-Object @{ Expression = { [int]$_.Post }; Ascending = $true }
)

if ($todayRows.Count -lt 2) {
    throw "Day $nextDay does not contain two unpublished posts. Found $($todayRows.Count). Review the CSV before running live."
}

$selected = @($todayRows | Select-Object -First $PostsPerRun)

Write-Step "Selected posts"
foreach ($row in $selected) {
    Write-Host "Day $($row.Day) / Post $($row.Post) / $($row.Photo_File)"
}

# -----------------------------
# Process selected posts
# -----------------------------
foreach ($row in $selected) {

    Write-Step "Processing Day $($row.Day) Post $($row.Post)"

    if ([string]::IsNullOrWhiteSpace([string]$row.Caption)) {
        throw "Caption is empty for Day $($row.Day) Post $($row.Post)."
    }

    if ($row.Caption.Length -gt 2200) {
        throw "Caption exceeds 2,200 characters for Day $($row.Day) Post $($row.Post)."
    }

    $jpegFile = Ensure-Jpeg -Row $row

    if ($jpegFile -ne [string]$row.Photo_File) {
        Write-Host "Updating CSV Photo_File: $($row.Photo_File) -> $jpegFile"
        $row.Photo_File = $jpegFile
        Save-Csv -Rows $rows

        if (-not $DryRun) {
            Commit-And-Push -Message "Prepare JPEG for Day $($row.Day) Post $($row.Post)"
        }
    }

    $imagePath = Join-Path $RepoPath $jpegFile
    if (-not (Test-Path -LiteralPath $imagePath)) {
        throw "Image file does not exist: $imagePath"
    }

    $imageUrl = Get-RawImageUrl -FileName $jpegFile

    Test-PublicImageUrl -Url $imageUrl

    if ($DryRun) {
        Write-Host "DRY RUN: would publish:" -ForegroundColor Yellow
        Write-Host "  Day       : $($row.Day)"
        Write-Host "  Post      : $($row.Post)"
        Write-Host "  Image     : $jpegFile"
        Write-Host "  Image URL : $imageUrl"
        Write-Host "  Caption   : $($row.Caption)"
        continue
    }

    $containerId = New-InstagramContainer `
        -ImageUrl $imageUrl `
        -Caption ([string]$row.Caption)

    Write-Host "Created Instagram container: $containerId"

    $ready = Wait-ForInstagramContainer -ContainerId $containerId
    if (-not $ready) {
        throw "Container was not ready for publication."
    }

    $mediaId = Publish-InstagramContainer -ContainerId $containerId

    $row.Published = "True"
    $row.Instagram_Media_ID = $mediaId
    $row.Published_At = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    Save-Csv -Rows $rows

    Commit-And-Push -Message "Publish Day $($row.Day) Post $($row.Post)"

    Write-Host ""
    Write-Host "SUCCESS" -ForegroundColor Green
    Write-Host "Day $($row.Day) Post $($row.Post) published."
    Write-Host "Instagram Media ID: $mediaId"
}

Write-Step "Run complete"
Write-Host "Processed $($selected.Count) post(s)." -ForegroundColor Green
