# Cloudflare Worker — Egg System web

Hosts the Flutter web build at `https://egg-system.<account>.workers.dev`.

## Deploy

1. Build Flutter web from repo root:

```bat
flutter build web --release --base-href /
```

2. Login once:

```bat
cd deploy\cloudflare
npx wrangler login
```

3. Deploy:

```bat
npx wrangler deploy
```

## Optional live camera link

Set a Worker secret to your Cloudflare Tunnel `/watch` URL:

```bat
npx wrangler secret put LIVE_WATCH_URL
```

Then `/live` on the Worker redirects to the farm camera page.
