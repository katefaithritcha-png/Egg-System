const fs = require("fs");
const path = require("path");
const https = require("https");

function getToken() {
  const f = path.join(process.env.APPDATA, "xdg.config/.wrangler/config/default.toml");
  const t = fs.readFileSync(f, "utf8");
  const m = t.match(/oauth_token\s*=\s*"([^"]+)"/);
  if (!m) throw new Error("no oauth token");
  return m[1];
}

function req(method, urlPath, body) {
  const token = getToken();
  const data = body ? JSON.stringify(body) : null;
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: "api.cloudflare.com",
        path: urlPath,
        method,
        headers: {
          Authorization: "Bearer " + token,
          "Content-Type": "application/json",
          ...(data ? { "Content-Length": Buffer.byteLength(data) } : {}),
        },
      },
      (res) => {
        let buf = "";
        res.on("data", (c) => (buf += c));
        res.on("end", () => {
          try {
            resolve({ status: res.statusCode, json: JSON.parse(buf) });
          } catch (e) {
            resolve({ status: res.statusCode, raw: buf });
          }
        });
      }
    );
    req.on("error", reject);
    if (data) req.write(data);
    req.end();
  });
}

(async () => {
  const account = "d210937da3b1a3798ea9c73c42e3f58a";
  const tunnelId = "596c500f-08b4-44e8-980e-156aed033469";
  const zones = await req("GET", "/client/v4/zones?per_page=50");
  const zoneNames = (zones.json.result || []).map((z) => z.name);
  console.log("ZONES=" + JSON.stringify(zoneNames));

  // Remotely managed ingress: localhost:8000 catch-all + 404 fallback
  const configBody = {
    config: {
      ingress: [
        { service: "http://127.0.0.1:8000" },
        { service: "http_status:404" },
      ],
    },
  };
  // If a zone exists, publish a stable hostname under it
  if (zoneNames.length) {
    const host = "egg-farm." + zoneNames[0];
    configBody.config.ingress = [
      { hostname: host, service: "http://127.0.0.1:8000" },
      { service: "http_status:404" },
    ];
    console.log("HOSTNAME=" + host);
  } else {
    console.log("HOSTNAME=");
  }

  const put = await req(
    "PUT",
    `/client/v4/accounts/${account}/cfd_tunnel/${tunnelId}/configurations`,
    configBody
  );
  console.log("CONFIG_STATUS=" + put.status);
  console.log("CONFIG_OK=" + !!(put.json && put.json.success));
  if (put.json && !put.json.success) {
    console.log("CONFIG_ERR=" + JSON.stringify(put.json.errors || put.json));
  }

  const tokenRes = await req(
    "GET",
    `/client/v4/accounts/${account}/cfd_tunnel/${tunnelId}/token`
  );
  console.log("TOKEN_OK=" + !!(tokenRes.json && tokenRes.json.success && tokenRes.json.result));
  if (tokenRes.json && tokenRes.json.result) {
    fs.writeFileSync(
      path.join(process.env.USERPROFILE, "cloudflared", "egg-farm-backend.token"),
      String(tokenRes.json.result).trim(),
      { mode: 0o600 }
    );
    console.log("TOKEN_FILE=saved");
  }
})().catch((e) => {
  console.error("FAIL=" + e.message);
  process.exit(1);
});
