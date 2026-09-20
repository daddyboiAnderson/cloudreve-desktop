# Cloudreve Desktop

![Hero Image](docs/hero.png)

<p>
  <a href="https://apps.microsoft.com/store/detail/9p3gh5rnnzfd">
    <img src="https://get.microsoft.com/images/en-us%20dark.svg" width="200"/>
  </a>
</p>

A desktop client for [Cloudreve](https://github.com/cloudreve/Cloudreve) cloud storage, built with Tauri and React. Provides seamless file synchronization using the Windows Cloud Files API and the native macOS File Provider framework.

## Features

### Windows

- Real-time bidirectional file synchronization
- On-demand file hydration (files download only when accessed)
- Windows Explorer integration (context menus, thumbnails, custom states)
- Multiple storage provider support, aligned with Cloudreve server
- System tray application

### macOS

- Native Finder integration through the macOS File Provider framework
- On-demand file downloads managed by macOS
- Real-time updates for remote file changes
- Create, rename, move, and delete files directly in Finder
- Multiple Cloudreve drives under Finder's Locations section
- Lightweight menu bar application
- Share items directly in Finder

## Prerequisites

### For Users

- Windows 10 version 1903 (build 18362) or later
- Microsoft Edge WebView2 Runtime (included with Windows 11 and current Windows 10 installs)
- macOS 13 or later
- A Cloudreve server instance

### For Developers

- **Windows 10/11**; [Developer Mode](https://learn.microsoft.com/en-us/windows/apps/get-started/enable-your-device-for-development) is needed for loose-package development registration
- **Rust** toolchain (install via [rustup](https://rustup.rs/))
- **Visual Studio 2022 Build Tools** with the **Desktop development with C++** workload
- **Node.js** 18+ and **Yarn**
- **Windows 10/11 SDK** with **Windows SDK Signing Tools** (for MSIX packaging and development signing)

Enable Developer Mode when using the loose-package `dev-install.ps1` workflow:
```
Settings → Privacy & security → For developers → Developer Mode → On
```

Install Rust targets for cross-compilation:
```powershell
rustup target add x86_64-pc-windows-msvc
rustup target add aarch64-pc-windows-msvc
```

### macOS Developers

- **macOS 13** or later
- **Xcode Command Line Tools** (`xcode-select --install`)
- **Rust** toolchain (install via [rustup](https://rustup.rs/))
- **Node.js** 18+ and **Yarn**

## Build & Run

### Quick Start (Development)

```powershell
# Enable the Yarn version bundled through Node's Corepack
corepack enable

# Install frontend dependencies
cd ui
yarn install
cd ..

# Run in development mode with hot reload
cargo tauri dev
```

### Release Build

```powershell
cargo tauri build
```

The built binary will be at `target/release/cloudreve-desktop.exe`.

### macOS Release Build

```bash
# Install frontend dependencies
cd ui
yarn install
cd ..

# Build the Tauri application bundle
npx --yes @tauri-apps/cli@2.11.4 build --bundles app

# Build and embed the native File Provider extension
FP_CONFIGURATION=Release FP_BUILD_NUMBER=5.1 ./macos/scripts/embed-into-app.sh \
  target/release/bundle/macos/Cloudreve.app
```

The built application will be at `target/release/bundle/macos/Cloudreve.app`.

The embed script builds the File Provider extension, places it inside the app bundle, ad-hoc signs the complete application, and registers the extension for local testing. A paid Apple Developer certificate is only required for notarized distribution builds.

Increment `FP_BUILD_NUMBER` for every packaged update. The app and embedded
File Provider receive the same build number so macOS can recognize the new
extension. This does not change domain IDs, sync anchors, or event processing;
use **Reset Finder Integration** only if macOS keeps a stale domain after an
ad-hoc app replacement.

## Development Installation (Full Feature Testing)

The basic `cargo tauri dev/build` only produces the binary. For testing **shell integration features** (context menus, thumbnails, cloud file states), you need to register the app as an MSIX package.

### Using dev-install.ps1

```powershell
# Build and register for development
.\dev-install.ps1

# Skip build if binary already exists
.\dev-install.ps1 -SkipBuild

# Use custom version
.\dev-install.ps1 -Version "0.2.0"
```

This script will:
1. Build the Tauri application (release mode)
2. Copy the binary to `package/`
3. Update `AppxManifest.xml` with correct architecture and version
4. Register the package with `Add-AppxPackage -Register`

### Unregister Development Package

```powershell
Get-AppxPackage *Cloudreve* | Remove-AppxPackage
```

## Building MSIX Packages

Use `build-msix.ps1` to create MSIX packages. Packages are unsigned unless a
signing option is selected.

```powershell
# Build for both x64 and ARM64, create bundle
.\build-msix.ps1

# Build for specific architecture
.\build-msix.ps1 -Arch x64
.\build-msix.ps1 -Arch arm64

# Skip build (use existing binaries)
.\build-msix.ps1 -SkipBuild

# Custom version
.\build-msix.ps1 -Version "1.0.0"

# Create a self-signed package for local testing
.\build-msix.ps1 -Arch x64 -SignForDevelopment

# Sign for public distribution with a certificate installed in Personal store
.\build-msix.ps1 -Arch x64 `
  -SigningCertificateThumbprint "YOUR_CERTIFICATE_THUMBPRINT" `
  -TimestampUrl "YOUR_PROVIDER_RFC3161_TIMESTAMP_URL"
```

Possible output files (depending on `-Arch` and whether development signing is enabled):
```
dist/
├── Cloudreve.x64.msix
├── Cloudreve.arm64.msix
├── Cloudreve.msixbundle
└── Cloudreve.Development.cer
```

`-SignForDevelopment` creates or reuses a non-exportable test-signing key in
the current user's Personal certificate store, signs the package, and exports
only its public certificate. It does not trust the certificate automatically.
To install the development package, first run this command in an elevated
PowerShell window:

```powershell
Import-Certificate `
  -FilePath ".\dist\Cloudreve.Development.cer" `
  -CertStoreLocation "Cert:\LocalMachine\TrustedPeople"
```

Then install the package with App Installer or PowerShell:

```powershell
Add-AppxPackage -Path ".\dist\Cloudreve.x64.msix"
```

If a development build with the same package identity and version is already
registered, either build with a higher four-part version (for example,
`-Version "0.2.0.1"`) or remove the existing package first:

```powershell
Get-AppxPackage -Name "2106abslant.Cloudreve" | Remove-AppxPackage
```

Developer Mode is not required to install this signed MSIX on Windows 10
version 2004 or later or on Windows 11 after its certificate is trusted. Older
Windows 10 versions may require the sideload-apps policy or Developer Mode.

Only trust this certificate on development/test computers. Remove it from the
Local Machine `Trusted People` store when testing is complete.

For direct public distribution, obtain an organization-validated code-signing
certificate from a publicly trusted provider and install it, with its private
key, in `CurrentUser\My` or `LocalMachine\My`. The public-signing command above
validates the certificate, changes the staged MSIX Publisher to its exact
subject, and timestamps every generated MSIX or bundle. It does not export or
copy the private key. Because the public certificate changes the MSIX package
identity from the development certificate, uninstall development builds before
installing the first public build. SmartScreen can still warn while a new app
builds reputation.

### Requirements for MSIX Building

- Windows SDK with `makeappx.exe` (automatically detected)
- Windows SDK Signing Tools (`signtool.exe`) when using either signing option
- A certificate from a trusted signing provider for production distribution;
  the generated development certificate is only for local testing

## Project Structure

```
├── src-tauri/           # Tauri application shell
├── crates/
│   ├── cloudreve-sync/  # Core sync service
│   ├── cloudreve-api/   # REST client for Cloudreve server
│   └── win32_notif/     # Windows notification utilities
├── ui/                  # React frontend (Vite + MUI)
├── macos/               # Native File Provider extension and build scripts
├── package/             # MSIX packaging assets
├── dev-install.ps1      # Dev build + register script
└── build-msix.ps1       # Production MSIX builder
```

## License

[MIT](LICENSE)
