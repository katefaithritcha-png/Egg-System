/**
 * Egg System — Cloudflare Worker front door.
 * Serves the Flutter web app from static assets and exposes /watch
 * as a redirect helper to the farm live camera (set LIVE_WATCH_URL).
 */
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Optional: point LIVE_WATCH_URL at your Cloudflare Tunnel /watch.
    if (url.pathname === '/live' || url.pathname === '/camera') {
      const live = (env.LIVE_WATCH_URL || '').trim();
      if (live) {
        return Response.redirect(live, 302);
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
