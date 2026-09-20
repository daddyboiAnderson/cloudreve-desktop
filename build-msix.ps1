<#
.SYNOPSIS
    Build MSIX packages and bundle for Cloudreve Desktop.

.DESCRIPTION
    This script cross-compiles the Tauri application for x64 and/or ARM64,
    creates MSIX packages using makeappx.exe from Windows SDK, and generates
    an MSIX bundle containing all architectures.

.PARAMETER Arch
    Target architecture: "x64", "arm64", or "all" (default: "all")

.PARAMETER Version
    Override the version from tauri.conf.json. Format: "X.Y.Z" (will be converted to "X.Y.Z.0")

.PARAMETER SkipBuild
    Skip the cargo build step (use existing binaries)

.PARAMETER OutputDir
    Output directory for MSIX files (default: "dist")

.PARAMETER SignForDevelopment
    Sign the generated packages with a self-signed development certificate.
    The private key stays non-exportable in the current user's Personal store and
    only the public certificate is exported beside the packages. The certificate
    is not trusted or installed automatically.

.PARAMETER SigningCertificateThumbprint
    Sign with a publicly trusted code-signing certificate from the current user
    or local machine Personal certificate store. The staged MSIX Publisher is
    changed to the certificate subject automatically.

.PARAMETER TimestampUrl
    RFC 3161 timestamp service used with SigningCertificateThumbprint. A trusted
    timestamp keeps the signature valid after the signing certificate expires.

.EXAMPLE
    .\build-msix.ps1
    # Build MSIX packages for both x64 and ARM64, then create bundle

.EXAMPLE
    .\build-msix.ps1 -Arch x64
    # Build MSIX package for x64 only (no bundle)

.EXAMPLE
    .\build-msix.ps1 -Arch arm64 -Version "1.0.0"
    # Build ARM64 package with custom version (no bundle)

.EXAMPLE
    .\build-msix.ps1 -Arch x64 -SignForDevelopment
    # Build and test-sign an x64 package, exporting Cloudreve.Development.cer

.EXAMPLE
    .\build-msix.ps1 -Arch x64 -SigningCertificateThumbprint "0123..." -TimestampUrl "https://timestamp.example.com"
    # Build and sign using an installed publicly trusted code-signing certificate
#>

param(
    [ValidateSet("x64", "arm64", "all")]
    [string]$Arch = "all",
    [string]$Version,
    [switch]$SkipBuild,
    [string]$OutputDir = "dist",
    [switch]$SignForDevelopment,
    [string]$SigningCertificateThumbprint,
    [string]$TimestampUrl
)

$ErrorActionPreference = "Stop"

# Paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TauriConfigPath = Join-Path $ScriptDir "src-tauri\tauri.conf.json"
$ManifestPath = Join-Path $ScriptDir "package\AppxManifest.xml"
$PackageDir = Join-Path $ScriptDir "package"
$OutputPath = Join-Path $ScriptDir $OutputDir

# Architecture mapping
$ArchMap = @{
    "x64" = @{
        RustTarget = "x86_64-pc-windows-msvc"
        MsixArch = "x64"
    }
    "arm64" = @{
        RustTarget = "aarch64-pc-windows-msvc"
        MsixArch = "arm64"
    }
}

# Find makeappx.exe from Windows SDK
function Find-MakeAppx {
    $SdkPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "$env:ProgramFiles\Windows Kits\10\bin"
    )

    foreach ($SdkPath in $SdkPaths) {
        if (Test-Path $SdkPath) {
            # Find all version directories and sort descending
            $Versions = Get-ChildItem $SdkPath -Directory |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
                Sort-Object { [Version]$_.Name } -Descending

            foreach ($Ver in $Versions) {
                $MakeAppx = Join-Path $Ver.FullName "x64\makeappx.exe"
                if (Test-Path $MakeAppx) {
                    return $MakeAppx
                }
            }
        }
    }

    return $null
}

# Find signtool.exe from Windows SDK
function Find-SignTool {
    $SdkPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "$env:ProgramFiles\Windows Kits\10\bin"
    )

    foreach ($SdkPath in $SdkPaths) {
        if (Test-Path $SdkPath) {
            $Versions = Get-ChildItem $SdkPath -Directory |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
                Sort-Object { [Version]$_.Name } -Descending

            foreach ($Ver in $Versions) {
                $SignTool = Join-Path $Ver.FullName "x64\signtool.exe"
                if (Test-Path $SignTool) {
                    return $SignTool
                }
            }
        }
    }

    return $null
}

function Get-OrCreateDevelopmentCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Publisher
    )

    $FriendlyName = "Cloudreve MSIX Development"
    $Now = Get-Date
    $Certificate = Get-ChildItem -Path "Cert:\CurrentUser\My" |
        Where-Object {
            $KeyUsage = $_.Extensions |
                Where-Object { $_.Oid.Value -eq "2.5.29.15" } |
                Select-Object -First 1
            $BasicConstraints = $_.Extensions |
                Where-Object { $_.Oid.Value -eq "2.5.29.19" } |
                Select-Object -First 1
            $HasDigitalSignature = $KeyUsage -and
                (($KeyUsage.KeyUsages -band [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature) -ne 0)
            $IsEndEntity = $BasicConstraints -and -not $BasicConstraints.CertificateAuthority

            $_.FriendlyName -eq $FriendlyName -and
            $_.Subject -ceq $Publisher -and
            $_.Issuer -ceq $_.Subject -and
            $_.HasPrivateKey -and
            $_.NotBefore -le $Now -and
            $_.NotAfter -gt $Now.AddDays(30) -and
            $HasDigitalSignature -and
            $IsEndEntity -and
            ($_.EnhancedKeyUsageList | Where-Object {
                $_.ObjectId -eq "1.3.6.1.5.5.7.3.3"
            })
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if (-not $Certificate) {
        Write-Host "Creating a self-signed development certificate..." -ForegroundColor Cyan
        $Certificate = New-SelfSignedCertificate `
            -Type Custom `
            -Subject $Publisher `
            -FriendlyName $FriendlyName `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -KeyUsage DigitalSignature `
            -KeyExportPolicy NonExportable `
            -HashAlgorithm SHA256 `
            -NotAfter $Now.AddYears(3) `
            -TextExtension @(
                "2.5.29.37={text}1.3.6.1.5.5.7.3.3",
                "2.5.29.19={text}"
            )
    } else {
        Write-Host "Reusing development certificate: $($Certificate.Thumbprint)" -ForegroundColor Cyan
    }

    return $Certificate
}

function Get-CodeSigningCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint
    )

    $NormalizedThumbprint = $Thumbprint.Replace(" ", "").ToUpperInvariant()
    $Now = Get-Date
    $Certificate = @(
        Get-ChildItem -Path "Cert:\CurrentUser\My", "Cert:\LocalMachine\My" |
            Where-Object { $_.Thumbprint -eq $NormalizedThumbprint }
    ) | Select-Object -First 1

    if (-not $Certificate) {
        Write-Error "No certificate with thumbprint '$NormalizedThumbprint' was found in CurrentUser\My or LocalMachine\My."
        exit 1
    }
    if (-not $Certificate.HasPrivateKey) {
        Write-Error "The signing certificate does not have an accessible private key."
        exit 1
    }
    if ($Certificate.NotBefore -gt $Now -or $Certificate.NotAfter -le $Now) {
        Write-Error "The signing certificate is not currently valid."
        exit 1
    }
    if (-not ($Certificate.EnhancedKeyUsageList | Where-Object {
        $_.ObjectId -eq "1.3.6.1.5.5.7.3.3"
    })) {
        Write-Error "The certificate is not valid for code signing."
        exit 1
    }

    return $Certificate
}

# Get version from tauri.conf.json if not provided
if (-not $Version) {
    Write-Host "Reading version from tauri.conf.json..." -ForegroundColor Cyan
    $TauriConfig = Get-Content $TauriConfigPath -Raw | ConvertFrom-Json
    $Version = $TauriConfig.version
}

# Convert to 4-part version for MSIX
$MsixVersion = if ($Version -match '^\d+\.\d+\.\d+$') {
    "$Version.0"
} elseif ($Version -match '^\d+\.\d+\.\d+\.\d+$') {
    $Version
} else {
    Write-Error "Invalid version format: $Version. Expected X.Y.Z or X.Y.Z.W"
    exit 1
}

Write-Host "Version: $MsixVersion" -ForegroundColor Cyan

# Find makeappx.exe
$MakeAppx = Find-MakeAppx
if (-not $MakeAppx) {
    Write-Error "Could not find makeappx.exe. Please install Windows SDK."
    exit 1
}
Write-Host "Found makeappx.exe: $MakeAppx" -ForegroundColor Cyan

$UseTrustedSigning = -not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)
if ($SignForDevelopment -and $UseTrustedSigning) {
    Write-Error "Choose either -SignForDevelopment or -SigningCertificateThumbprint, not both."
    exit 1
}
if ($UseTrustedSigning -and [string]::IsNullOrWhiteSpace($TimestampUrl)) {
    Write-Error "-TimestampUrl is required when using a publicly trusted signing certificate."
    exit 1
}

$SignTool = $null
if ($SignForDevelopment -or $UseTrustedSigning) {
    $SignTool = Find-SignTool
    if (-not $SignTool) {
        Write-Error "Could not find signtool.exe. Please install the Windows SDK Signing Tools feature."
        exit 1
    }
    Write-Host "Found signtool.exe: $SignTool" -ForegroundColor Cyan
}

$TrustedSigningCertificate = $null
$PackagePublisher = $null
if ($UseTrustedSigning) {
    $TrustedSigningCertificate = Get-CodeSigningCertificate -Thumbprint $SigningCertificateThumbprint
    $PackagePublisher = $TrustedSigningCertificate.Subject
    Write-Host "Trusted signing certificate: $($TrustedSigningCertificate.Subject)" -ForegroundColor Cyan
    Write-Host "MSIX publisher will be set to: $PackagePublisher" -ForegroundColor Cyan
}

# Determine architectures to build
$TargetArchs = if ($Arch -eq "all") { @("x64", "arm64") } else { @($Arch) }

Write-Host "Target architectures: $($TargetArchs -join ', ')" -ForegroundColor Cyan

# Create output directory
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Create temp directory for package staging
$TempBaseDir = Join-Path $env:TEMP "cloudreve-msix-build"
if (Test-Path $TempBaseDir) {
    Remove-Item $TempBaseDir -Recurse -Force
}
New-Item -ItemType Directory -Path $TempBaseDir -Force | Out-Null

# Track created MSIX files for bundling
$CreatedMsixFiles = @()
$BundlePath = $null

# Build for each architecture
foreach ($TargetArch in $TargetArchs) {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Building for $TargetArch" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    $Config = $ArchMap[$TargetArch]
    $RustTarget = $Config.RustTarget
    $MsixArch = $Config.MsixArch

    # Build the application
    if (-not $SkipBuild) {
        Write-Host "`nBuilding frontend for production..." -ForegroundColor Cyan

        Push-Location $ScriptDir
        try {
            npm run build --prefix ui
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Frontend build failed with exit code $LASTEXITCODE"
                exit $LASTEXITCODE
            }

            Write-Host "`nBuilding Tauri application for $RustTarget..." -ForegroundColor Cyan
            # custom-protocol selects Tauri's production asset protocol. Without
            # it, a release binary still loads build.devUrl (localhost:5173).
            cargo build --package cloudreve-desktop --release --target $RustTarget --features tauri/custom-protocol
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Build failed for $TargetArch with exit code $LASTEXITCODE"
                exit $LASTEXITCODE
            }
        } finally {
            Pop-Location
        }
    } else {
        Write-Host "`nSkipping build step..." -ForegroundColor Yellow
    }

    # Determine binary path
    $BinaryPath = Join-Path $ScriptDir "target\$RustTarget\release\cloudreve-desktop.exe"
    if (-not (Test-Path $BinaryPath)) {
        Write-Error "Binary not found at: $BinaryPath"
        exit 1
    }

    # Create temp directory for this architecture
    $TempPackageDir = Join-Path $TempBaseDir $MsixArch
    Write-Host "Copying package to temp directory: $TempPackageDir" -ForegroundColor Cyan
    Copy-Item $PackageDir -Destination $TempPackageDir -Recurse -Force

    # Copy binary to temp package directory
    Write-Host "Copying binary..." -ForegroundColor Cyan
    Copy-Item $BinaryPath -Destination $TempPackageDir -Force

    # Update AppxManifest.xml in temp directory
    $TempManifestPath = Join-Path $TempPackageDir "AppxManifest.xml"
    Write-Host "Updating AppxManifest.xml for $MsixArch..." -ForegroundColor Cyan

    $ManifestContent = Get-Content $TempManifestPath -Raw -Encoding UTF8

    # Replace placeholders
    $ManifestContent = $ManifestContent -replace '__ARCH__', $MsixArch
    $ManifestContent = $ManifestContent -replace '__VERSION__', $MsixVersion

    if ($PackagePublisher) {
        [xml]$StagedManifest = $ManifestContent
        $StagedManifest.Package.Identity.Publisher = $PackagePublisher
        $ManifestContent = $StagedManifest.OuterXml
    }

    # Write back with UTF-8 BOM
    $Utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($TempManifestPath, $ManifestContent, $Utf8Bom)

    # Create MSIX package
    $MsixPath = Join-Path $OutputPath "Cloudreve.$MsixArch.msix"
    Write-Host "Creating MSIX package: $MsixPath" -ForegroundColor Cyan

    # Remove existing package if present
    if (Test-Path $MsixPath) {
        Remove-Item $MsixPath -Force
    }

    & $MakeAppx pack /v /p $MsixPath /d $TempPackageDir
    if ($LASTEXITCODE -ne 0) {
        Write-Error "makeappx.exe pack failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }

    Write-Host "Created: $MsixPath" -ForegroundColor Green
    $CreatedMsixFiles += $MsixPath
}

# Create bundle if building for all architectures
if ($Arch -eq "all" -and $CreatedMsixFiles.Count -gt 1) {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Creating MSIX Bundle" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    $BundlePath = Join-Path $OutputPath "Cloudreve.msixbundle"

    # Remove existing bundle if present
    if (Test-Path $BundlePath) {
        Remove-Item $BundlePath -Force
    }

    # Give MakeAppx an isolated directory containing only this run's packages.
    # Pointing it at dist can accidentally bundle stale packages from older runs.
    $BundleInputDir = Join-Path $TempBaseDir "bundle-input"
    New-Item -ItemType Directory -Path $BundleInputDir -Force | Out-Null
    foreach ($CreatedMsixFile in $CreatedMsixFiles) {
        Copy-Item $CreatedMsixFile -Destination $BundleInputDir -Force
    }

    Write-Host "Creating bundle: $BundlePath" -ForegroundColor Cyan
    & $MakeAppx bundle /v /d $BundleInputDir /p $BundlePath /bv $MsixVersion
    if ($LASTEXITCODE -ne 0) {
        Write-Error "makeappx.exe bundle failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }

    Write-Host "Created: $BundlePath" -ForegroundColor Green
}

# Sign final artifacts only after bundle creation. A signed bundle covers its
# embedded packages, while the standalone MSIX files are signed for direct use.
if ($SignForDevelopment -or $UseTrustedSigning) {
    Write-Host "`n========================================" -ForegroundColor Green
    if ($SignForDevelopment) {
        Write-Host "Signing for local development" -ForegroundColor Green
    } else {
        Write-Host "Signing for public distribution" -ForegroundColor Green
    }
    Write-Host "========================================" -ForegroundColor Green

    if ($SignForDevelopment) {
        [xml]$SourceManifest = Get-Content $ManifestPath -Raw -Encoding UTF8
        $Publisher = $SourceManifest.Package.Identity.Publisher
        if ([string]::IsNullOrWhiteSpace($Publisher)) {
            Write-Error "The package manifest does not contain an Identity Publisher."
            exit 1
        }

        $Certificate = Get-OrCreateDevelopmentCertificate -Publisher $Publisher
        if ($Certificate.Subject -cne $Publisher) {
            Write-Error "Certificate subject '$($Certificate.Subject)' does not match manifest publisher '$Publisher'."
            exit 1
        }

        $CertificatePath = Join-Path $OutputPath "Cloudreve.Development.cer"
        Export-Certificate -Cert $Certificate -FilePath $CertificatePath -Type CERT -Force | Out-Null
        Write-Host "Exported public certificate: $CertificatePath" -ForegroundColor Green
    } else {
        $Certificate = $TrustedSigningCertificate
    }
    Write-Host "Certificate thumbprint: $($Certificate.Thumbprint)" -ForegroundColor Cyan

    $ArtifactsToSign = @($CreatedMsixFiles)
    if ($BundlePath -and (Test-Path $BundlePath)) {
        $ArtifactsToSign += $BundlePath
    }

    foreach ($ArtifactPath in $ArtifactsToSign) {
        Write-Host "Signing: $ArtifactPath" -ForegroundColor Cyan
        if ($UseTrustedSigning) {
            & $SignTool sign /v /fd SHA256 /sha1 $Certificate.Thumbprint /tr $TimestampUrl /td SHA256 $ArtifactPath
        } else {
            & $SignTool sign /v /fd SHA256 /sha1 $Certificate.Thumbprint $ArtifactPath
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Error "signtool.exe failed for '$ArtifactPath' with exit code $LASTEXITCODE"
            exit $LASTEXITCODE
        }

        $Signature = Get-AuthenticodeSignature -FilePath $ArtifactPath
        if (-not $Signature.SignerCertificate -or
            $Signature.SignerCertificate.Thumbprint -ne $Certificate.Thumbprint) {
            Write-Error "The expected signature was not found on '$ArtifactPath'."
            exit 1
        }
        Write-Host "Signed with: $($Signature.SignerCertificate.Subject)" -ForegroundColor Green
    }

    if ($SignForDevelopment) {
        Write-Host "`nThe certificate was NOT added to a trust store." -ForegroundColor Yellow
        Write-Host "Before installing, import the exported .cer into LocalMachine\TrustedPeople from an elevated PowerShell window." -ForegroundColor Yellow
    } else {
        Write-Host "`nThe package has a publicly trusted, timestamped signature." -ForegroundColor Green
        Write-Host "SmartScreen may still warn until the application builds reputation." -ForegroundColor Yellow
    }
}

# Cleanup temp directory
Write-Host "`nCleaning up temp directory..." -ForegroundColor Cyan
Remove-Item $TempBaseDir -Recurse -Force

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Build complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Output files:" -ForegroundColor Cyan
$CreatedArtifacts = @($CreatedMsixFiles)
if ($BundlePath -and (Test-Path $BundlePath)) {
    $CreatedArtifacts += $BundlePath
}
foreach ($CreatedArtifact in $CreatedArtifacts) {
    Write-Host "  $CreatedArtifact" -ForegroundColor White
}
if ($SignForDevelopment) {
    Write-Host "  $CertificatePath" -ForegroundColor White
}
