/**
 * Egg System — Cloudflare Worker front door.
 * Serves Flutter web assets and (when FARM_ORIGIN is set) proxies live
 * farm API / camera routes to the Cloudflare Tunnel URL.
 *
 * Secrets / vars:
 *   FARM_ORIGIN     e.g. https://xxxx.trycloudflare.com  (no trailing slash)
 *   LIVE_WATCH_URL  optional full /watch URL (defaults to FARM_ORIGIN/watch)
 */
const PROXY_PREFIXES = [
  '/api/',
  '/auth/',
  '/metrics',
  '/records',
  '/health',
  '/debug',
  '/reset',
  '/weight',
  '/frame',
  '/status',
  '/stream',
  '/live.jpg',
  '/live.jpgg',
  '/live-status',
  '/watch',
  '/live',
  '/camera',
  '/docs',
  '/openapi.json',
];

function shouldProxy(pathname) {
  return PROXY_PREFIXES.some(
    (p) => pathname === p || pathname.startsWith(p.endsWith('/') ? p : p + '/') || pathname === p.replace(/\/$/, ''),
  );
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const farm = (env.FARM_ORIGIN || '').trim().replace(/\/$/, '');

    if (url.pathname === '/live' || url.pathname === '/camera') {
      const live = (env.LIVE_WATCH_URL || (farm ? `${farm}/watch` : '')).trim();
      if (live) {
        return Response.redirect(live, 302);
      }
    }

    if (farm && shouldProxy(url.pathname)) {
      const target = new URL(farm + url.pathname + url.search);
      const headers = new Headers(request.headers);
      headers.delete('host');
      const init = {
        method: request.method,
        headers,
        redirect: 'follow',
      };
      if (request.method !== 'GET' && request.method !== 'HEAD') {
        init.body = request.body;
        // Required for streaming request bodies in Workers.
        init.duplex = 'half';
      }
      try {
        const upstream = await fetch(target, init);
        const path = url.pathname;
        // Live board must never be CDN/browser-cached — stale /records forced a reload.
        if (
          path === '/metrics' ||
          path === '/records' ||
          path.startsWith('/records/') ||
          path === '/health' ||
          path === '/live-status' ||
          path === '/status'
        ) {
          const headers = new Headers(upstream.headers);
          headers.set('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
          headers.set('Pragma', 'no-cache');
          headers.set('CDN-Cache-Control', 'no-store');
          return new Response(upstream.body, {
            status: upstream.status,
            statusText: upstream.statusText,
            headers,
          });
        }
        return upstream;
      } catch (err) {
        return new Response(
          JSON.stringify({
            ok: false,
            error: 'farm_unreachable',
            detail: String(err && err.message ? err.message : err),
          }),
          {
            status: 502,
            headers: {
              'content-type': 'application/json; charset=utf-8',
              'Cache-Control': 'no-store',
            },
          },
        );
      }
    }

    if (env.ASSETS) {
      return env.ASSETS.fetch(request);
    }

    return new Response(
      '<!doctype html><html><body style="font-family:sans-serif;padding:2rem">' +
        '<h1>Egg System</h1>' +
        '<p>Static assets missing. Deploy with <code>npx wrangler deploy</code> from deploy/cloudflare.</p>' +
        '</body></html>',
      { headers: { 'content-type': 'text/html; charset=utf-8' } },
    );
  },
};
