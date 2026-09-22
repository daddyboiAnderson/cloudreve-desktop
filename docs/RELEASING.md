# Releases

The production identifiers are `cloudreve.desktop` and
`cloudreve.desktop.fileprovider`. Keep them stable after 0.2.1. The transition
from `.dev` requires the reconnect steps in `releases/0.2.1.md`; do not silently
delete old domains, private state or downloaded content.

## macOS (Apple silicon)

1. Increment the version in `src-tauri/Cargo.toml` and `tauri.conf.json`, and
   add versioned release notes. Increment `FP_BUILD_NUMBER` for every build.
2. Run frontend, Rust and Swift tests and the native Windows CI job.
3. Build and embed in this order:

   ```sh
   cargo tauri build --bundles app
   FP_CONFIGURATION=Release FP_REGISTER_EXTENSION=0 \
     FP_SHORT_VERSION=0.2.1 FP_BUILD_NUMBER=184 \
     bash macos/scripts/embed-into-app.sh
   TAURI_SIGNING_PRIVATE_KEY_PATH=/secure/path/updater.key \
     TAURI_SIGNING_PRIVATE_KEY_PASSWORD='' \
     bash macos/scripts/package-release.sh
   ```

4. Verify the DMG, matching app/extension versions, signature, and updater archive
   contents. Test the package on macOS. Do not overwrite an installed app while
   documents are being edited. Test a two-version in-app upgrade before claiming
   end-to-end updater validation.
5. Commit and push the tested source. Create tag `v<VERSION>` on that exact commit.
   Publish the DMG, `.app.tar.gz`, `.app.tar.gz.sig`, and `latest.json` from
   `release/<VERSION>/` to a GitHub release with the same tag. Upload assets to a
   draft first, verify all assets exist, then publish it as latest. Never publish
   `latest.json` pointing to an absent or differently signed archive.

The endpoint is this fork's GitHub `releases/latest/download/latest.json`.
Only macOS in-place updates are enabled. Windows uses its established MSIX
package workflow; NSIS/MSI replacement would lose package identity and Explorer
integration. Do not advertise a Windows updater asset until its package upgrade
path is implemented and tested on Windows.

The updater private key is stored outside Git and outside `.cloudreve`. Back it
up securely: losing it prevents future updates for installed clients. Only its
public key belongs in `tauri.conf.json`. Do not print the private key or include
it in artifacts. A key rotation requires a separately planned trust transition.
The example explicitly supplies an empty password for the current passwordless
key. For an encrypted key, supply its real password through a secret environment
variable instead; do not put that password in shell history or committed files.

App bundles must be archived and signed **after** embedding the extension and
re-signing the outer bundle. Tauri's automatic pre-embedding updater artifacts
are deliberately disabled. The DMG and updater archive use the same final app.

Current releases use ad-hoc code signing. This is distinct from the mandatory
updater-package signature. Without Developer ID signing and notarization, there
is no guarantee that Gatekeeper only prompts on first installation. Never
disable security checks or remove quarantine as a packaging workaround.

## Development artifacts

Debug binaries, development servers, test hosts, module caches, signing keys and
manual state backups must not be included in published assets. Diagnostic log
controls remain available to users, but release defaults use Info, not Debug.
Development URLs in Tauri build configuration are build-time only; production
bundles must be built using `cargo tauri build`, not a raw release executable.
