const fs = require("fs");
const path = require("path");
const https = require("https");
function getToken() {
  const f = path.join(process.env.APPDATA, "xdg.config/.wrangler/config/default.toml");
  return fs.readFileSync(f, "utf8").match(/oauth_token\s*=\s*"([^"]+)"/)[1];
}
function req(method, urlPath) {
  const token = getToken();
  return new Promise((resolve, reject) => {
    const r = https.request({
      hostname: "api.cloudflare.com", path: urlPath, method,
      headers: { Authorization: "Bearer " + token },
    }, (res) => { let buf=""; res.on("data", c => buf+=c); res.on("end", () => { try { resolve(JSON.parse(buf)); } catch { resolve({raw:buf}); }}); });
    r.on("error", reject); r.end();
  });
}
(async () => {
  const zones = await req("GET", "/client/v4/zones?per_page=50");
  for (const z of (zones.result||[])) {
    console.log("ZONE", z.name, z.status, z.id);
    const dns = await req("GET", `/client/v4/zones/${z.id}/dns_records?per_page=100`);
    for (const r of (dns.result||[])) {
      console.log("DNS", r.type, r.name, "->", r.content, "proxied="+r.proxied);
    }
  }
})().catch(e => console.error(e.message));
