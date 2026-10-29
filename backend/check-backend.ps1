param(
  [string]$Url = 'https://egg-farm.eggsorting.site/health',
  [int]$TimeoutSec = 120
)

$ErrorActionPreference = 'Continue'
$deadline = (Get-Date).AddSeconds($TimeoutSec)
Write-Host "Waiting for $Url (up to ${TimeoutSec}s) ..."

while ((Get-Date) -lt $deadline) {
  try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8
    if ($r.StatusCode -eq 200 -and $r.Content -match 'ready|ok|"backend"') {
      Write-Host "OK $($r.StatusCode) $($r.Content.Substring(0, [Math]::Min(120, $r.Content.Length)))"
      exit 0
    }
  } catch {
    # keep waiting
  }
  Start-Sleep -Seconds 2
}

Write-Host "ERROR: timed out waiting for $Url"
exit 1
