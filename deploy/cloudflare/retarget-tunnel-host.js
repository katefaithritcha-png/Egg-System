const fs = require("fs");
const path = require("path");
const https = require("https");
function getToken() {
  const f = path.join(process.env.APPDATA, "xdg.config/.wrangler/config/default.toml");
  const t = fs.readFileSync(f, "utf8");
  return t.match(/oauth_token\s*=\s*"([^"]+)"/)[1];
}
function req(method, urlPath, body) {
  const token = getToken();
  const data = body ? JSON.stringify(body) : null;
  return new Promise((resolve, reject) => {
    const r = https.request({
      hostname: "api.cloudflare.com", path: urlPath, method,
      headers: { Authorization: "Bearer " + token, "Content-Type": "application/json", ...(data ? {"Content-Length": Buffer.byteLength(data)} : {}) },
    }, (res) => { let buf=""; res.on("data", c => buf+=c); res.on("end", () => { try { resolve({status:res.statusCode, json:JSON.parse(buf)});} catch { resolve({status:res.statusCode, raw:buf}); }}); });
    r.on("error", reject); if (data) r.write(data); r.end();
  });
}
(async () => {
  const account = "d210937da3b1a3798ea9c73c42e3f58a";
  const tunnelId = "596c500f-08b4-44e8-980e-156aed033469";
  const host = "egg-farm.eggsorting.site";
  const put = await req("PUT", `/client/v4/accounts/${account}/cfd_tunnel/${tunnelId}/configurations`, {
    config: {
      ingress: [
        { hostname: host, service: "http://127.0.0.1:8000" },
        { service: "http_status:404" },
      ],
    },
  });
  console.log("CONFIG_OK=" + !!(put.json && put.json.success));
  if (put.json && !put.json.success) console.log(JSON.stringify(put.json.errors));
  const zones = await req("GET", "/client/v4/zones?per_page=50");
  console.log("ZONES=" + JSON.stringify((zones.json.result||[]).map(z=>({name:z.name,status:z.status}))));
})().catch(e => { console.error("FAIL="+e.message); process.exit(1); });
