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
  const zones = await req("GET", "/client/v4/zones?per_page=50");
  console.log(JSON.stringify((zones.json.result||[]).map(z => ({id:z.id,name:z.name,status:z.status})), null, 2));
  const zone = (zones.json.result||[]).find(z => z.name === "eggsorting.site" || z.name.includes("egg"));
  if (!zone) throw new Error("no egg zone");
  const tunnelId = "596c500f-08b4-44e8-980e-156aed033469";
  const host = "egg-farm." + zone.name;
  const target = tunnelId + ".cfargotunnel.com";
  const existing = await req("GET", `/client/v4/zones/${zone.id}/dns_records?type=CNAME&per_page=100`);
  const recs = (existing.json.result||[]).filter(r => r.name === host || r.name.startsWith("egg-farm."));
  console.log("EXISTING=" + JSON.stringify(recs.map(r=>({id:r.id,name:r.name,content:r.content}))));
  if (recs.length) {
    const upd = await req("PUT", `/client/v4/zones/${zone.id}/dns_records/${recs[0].id}`, { type:"CNAME", name:"egg-farm", content:target, proxied:true, ttl:1 });
    console.log("DNS_OK=" + !!(upd.json&&upd.json.success) + " ERR=" + JSON.stringify(upd.json&&upd.json.errors));
  } else {
    const cre = await req("POST", `/client/v4/zones/${zone.id}/dns_records`, { type:"CNAME", name:"egg-farm", content:target, proxied:true, ttl:1 });
    console.log("DNS_OK=" + !!(cre.json&&cre.json.success) + " ERR=" + JSON.stringify(cre.json&&cre.json.errors));
  }
  console.log("STABLE_URL=https://" + host);
})().catch(e => { console.error("FAIL="+e.message); process.exit(1); });
