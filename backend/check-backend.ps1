param(
  [int]$TimeoutSec = 90,
  [string]$Url = 'http://192.168.11.212:8000/health'
)

$deadline = (Get-Date).AddSeconds($TimeoutSec)
Write-Host ("Waiting for {0} (up to {1}s)..." -f $Url, $TimeoutSec)

while ((Get-Date) -lt $deadline) {
  try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 4
    if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
      # Gateway may return 503 while app boots; keep waiting for real ready.
      $body = ''
      try { $body = [string]$r.Content } catch {}
      if ($r.StatusCode -eq 200 -or ($body -match '"backend"\s*:\s*"ready"' -or $body -match '"ok"\s*:\s*true')) {
        if ($body -notmatch 'backend_starting') {
          Write-Host ("OK {0} -> {1}" -f $r.StatusCode, $body.Substring(0, [Math]::Min(120, $body.Length)))
          exit 0
        }
      }
    }
  } catch {
    # still starting
  }
  Start-Sleep -Seconds 2
}

Write-Host "ERROR: backend health check timed out."
exit 1
