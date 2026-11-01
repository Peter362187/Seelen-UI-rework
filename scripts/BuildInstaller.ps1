# Builds a local, self-signed NSIS installer of this fork and copies it to the Desktop.
#
# Release builds sign static/SHA256SUMS (see src/build.rs) and the app verifies that signature on
# startup. Forks don't have the upstream private key, so a local key pair is generated once and its
# public key is baked into the binary via SLU_BUNDLE_PUBLIC_KEY (see utils/integrity/checksums.rs).
#
# Requirements: Node.js, Deno, rustup and the Visual Studio C++ Build Tools.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$keyDir = Join-Path $env:USERPROFILE ".seelen-fork-keys"
$keyFile = Join-Path $keyDir "seelen-fork.key"
$pwdFile = Join-Path $keyDir "seelen-fork.key.pwd"

function Invoke-Step([string]$name, [scriptblock]$block) {
  Write-Host "`n==> $name" -ForegroundColor Cyan
  # Windows PowerShell turns native stderr (npm/cargo warnings) into errors when output is
  # redirected, so failures are detected by exit code only.
  $ErrorActionPreference = "Continue"
  & $block
  if ($LASTEXITCODE -ne 0) {
    throw "$name failed (exit code $LASTEXITCODE)"
  }
}

# checks for the CLI instead of node_modules itself, which an aborted install leaves half-filled
if (-not (Test-Path "node_modules/.bin/tauri.cmd")) {
  # node_modules is needed for the tauri CLI, so the install runs before the key generation.
  # Its preinstall step (build:lib) only needs Rust, not the signing key.
  Invoke-Step "npm install" { npm install }
}

if (-not (Test-Path $keyFile)) {
  New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
  $password = [Guid]::NewGuid().ToString("N")
  Set-Content -Path $pwdFile -Value $password -NoNewline -Encoding ascii
  Invoke-Step "Generate signing key" { npx tauri signer generate --ci -w $keyFile -p $password -f }
}

$env:TAURI_SIGNING_PRIVATE_KEY = (Get-Content $keyFile -Raw).Trim()
$env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = (Get-Content $pwdFile -Raw).Trim()
$env:SLU_BUNDLE_PUBLIC_KEY = (Get-Content "$keyFile.pub" -Raw).Trim()

Invoke-Step "Build hook DLL" { cargo build --release -p sluhk }
# Updater artifacts are only needed for official releases (tauri.conf.json has no updater pubkey),
# and creating them would fail here. A config file avoids JSON quoting issues on the command line.
$overrides = Join-Path $env:TEMP "seelen-fork.tauri.conf.json"
Set-Content -Path $overrides -Value '{ "bundle": { "createUpdaterArtifacts": false } }' -Encoding ascii
Invoke-Step "Build app and installer" { npx tauri build --config $overrides }

$installer = Get-ChildItem "target/release/bundle/nsis" -Filter "*-setup.exe" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $installer) {
  throw "No installer found in target/release/bundle/nsis"
}

$desktop = [Environment]::GetFolderPath("Desktop")
Copy-Item $installer.FullName -Destination $desktop -Force
Write-Host "`nInstaller ready: $(Join-Path $desktop $installer.Name)" -ForegroundColor Green
