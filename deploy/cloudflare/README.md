# Cloudflare Worker â€” Egg System web

Hosts the Flutter web build at `https://egg-system.paghasianjustine.workers.dev`.

Farm PC backend stays local (camera + GATE need LAN). The Worker proxies API calls
through a Cloudflare Tunnel.

## Stable setup (named tunnel)

Tunnel name: `egg-farm-backend`  
Tunnel ID: `596c500f-08b4-44e8-980e-156aed033469`  
Stable farm URL: `https://egg-farm.eggsorting.site`

### One-time DNS

See `DNS-SETUP.txt`. Domain `eggsorting.site` must be Active in Cloudflare, then add:

- CNAME `egg-farm` â†’ `596c500f-08b4-44e8-980e-156aed033469.cfargotunnel.com` (Proxied)

Until DNS works, `start-egg-tunnel-smart.bat` falls back to a quick tunnel and
auto-updates `FARM_ORIGIN`.

### Daily use

1. `c:\Egg System\start-egg-farm.bat`  
   or reboot (Windows login Run key `EggSystemFarm` auto-starts it)
2. Open only: `https://egg-system.paghasianjustine.workers.dev`
3. Never bookmark `:8000` or `*.trycloudflare.com`

### Deploy Flutter web

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File deploy\cloudflare\deploy.ps1
```

### Secrets

```bat
cd deploy\cloudflare
echo https://egg-farm.eggsorting.site| npx wrangler secret put FARM_ORIGIN
```
