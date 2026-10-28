# Post-build: disable Flutter service worker + force local CanvasKit.
$bootstrap = Join-Path $PSScriptRoot "..\..\build\web\flutter_bootstrap.js"
if (-not (Test-Path $bootstrap)) {
  Write-Error ('Missing {0} - run flutter build web first.' -f $bootstrap)
  exit 1
}

$text = Get-Content -Raw -Path $bootstrap
$patched = [regex]::Replace(
  $text,
  '(?s)_flutter\.loader\.load\(\{.*?\}\);',
  @"
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "/canvaskit/"
  }
});
"@
)
if ($patched -eq $text -and $text -notmatch 'canvasKitBaseUrl') {
  Write-Error 'Could not patch flutter_bootstrap.js load call.'
  exit 1
}
Set-Content -Path $bootstrap -Value $patched -NoNewline
Write-Host 'Patched flutter_bootstrap.js (local CanvasKit, no service worker).'
