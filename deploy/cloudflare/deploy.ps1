# Build Flutter web (local CanvasKit), strip service worker, deploy Worker.
# Uses Program Files Node so Firebase's PATH shim does not hijack wrangler.

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$node = "C:\Program Files\NodeJS\node.exe"
$wrangler = Join-Path $PSScriptRoot "node_modules\wrangler\bin\wrangler.js"

if (-not (Test-Path $node)) {
  throw "Node not found at $node"
}
if (-not (Test-Path $wrangler)) {
  throw "Wrangler missing - run npm install in deploy\cloudflare first."
}

Set-Location $root
flutter build web --release --base-href / --no-wasm-dry-run --no-web-resources-cdn
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

& (Join-Path $PSScriptRoot "patch-web-bootstrap.ps1")

# Keep SW/cache purge in shipped index.html (flutter rebuild overwrites build/web/index.html).
$indexSrc = Join-Path $root "web\index.html"
$indexDst = Join-Path $root "build\web\index.html"
Copy-Item -Force $indexSrc $indexDst

Set-Location $PSScriptRoot
& $node $wrangler deploy
