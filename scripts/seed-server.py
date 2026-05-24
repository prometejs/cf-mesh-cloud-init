#!/usr/bin/env python3
"""Seed server: cloud-init NoCloud user-data, meta-data, and tunnel 
secret, keyed by the booting node's primary-NIC MAC.

State source:  cf-mesh-terraform-infra Terraform state on S3.
Site lookup:   site_inventory[*].tags.mac == path MAC (hyphen-lower).

Endpoints:
  GET /seed/<mac>/user-data   rendered cloud-config (no secrets baked in)
  GET /seed/<mac>/meta-data   instance-id + local-hostname
  GET /seed/<mac>/secret      {"warp_orchestration_token": "..."}
"""

import json, os, re, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

S3_BUCKET     = os.environ["S3_BUCKET"]
S3_KEY        = os.environ["S3_KEY"]
S3_REGION     = os.environ.get("S3_REGION", "")
INVENTORY_KEY = os.environ.get("INVENTORY_KEY", "site_inventory.value")
BIND_HOST     = os.environ.get("BIND_HOST", "0.0.0.0")
BIND_PORT     = int(os.environ.get("BIND_PORT", "8080"))
CACHE_TTL     = int(os.environ.get("CACHE_TTL", "120"))
HERE          = os.path.dirname(os.path.abspath(__file__))
TEMPLATE      = os.environ.get("TEMPLATE", os.path.join(HERE, "..", "cloud-init", "user-data.tpl"))

MAC_RE  = re.compile(r"^[0-9a-f]{2}(-[0-9a-f]{2}){5}$")
PATH_RE = re.compile(r"^/seed/([^/]+)/(user-data|meta-data|secret)$")
PH_RE   = re.compile(r"\{\{([A-Z_][A-Z0-9_]*)\}\}")

_cache, _cache_t, _lock = None, 0.0, threading.Lock()

def fetch_state():
    cmd = ["aws", "s3", "cp"]
    if S3_REGION:
        cmd += ["--region", S3_REGION]
    cmd += [f"s3://{S3_BUCKET}/{S3_KEY}", "-"]
    obj = json.loads(subprocess.check_output(cmd))
    for k in ["outputs"] + INVENTORY_KEY.split("."):
        obj = obj[k]
    return obj

def get_inventory():
    global _cache, _cache_t
    with _lock:
        if _cache is None or time.time() - _cache_t > CACHE_TTL:
            _cache, _cache_t = fetch_state(), time.time()
        return _cache

def _norm_mac(mac):
    return re.sub(r"[^0-9a-f]", "", mac.lower())

def find_site(mac):
    mac = _norm_mac(mac)
    for name, rec in get_inventory().items():
        if _norm_mac(rec.get("tags", {}).get("mac", "")) == mac:
            return name, rec
    return None

def render_user_data(name):
    with open(TEMPLATE) as f:
        tpl = f.read()
    values = dict(os.environ)
    values["HOSTNAME"] = name
    def sub(m):
        v = values.get(m.group(1), "")
        if not v:
            raise KeyError(m.group(1))
        return v
    return PH_RE.sub(sub, tpl)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        m = PATH_RE.match(self.path)
        if not m:
            return self.send_error(404)
        mac, kind = m.group(1).lower(), m.group(2)
        if not MAC_RE.match(mac):
            return self.send_error(400, "invalid MAC (expected hyphen-lower, e.g. 08-00-27-aa-bb-cc)")
        found = find_site(mac)
        if not found:
            return self.send_error(404, f"no site for MAC {mac}")
        name, rec = found
        try:
            if kind == "user-data":
                body = render_user_data(name).encode()
                ct = "text/plain; charset=utf-8"
            elif kind == "meta-data":
                body = f"instance-id: {name}\nlocal-hostname: {name}\n".encode()
                ct = "text/plain; charset=utf-8"
            else:
                body = json.dumps({"warp_orchestration_token": rec["tunnel_token"]}).encode()
                ct = "application/json"
        except KeyError as e:
            return self.send_error(500, f"missing data for {name}: {e}")
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

def main():
    sys.stderr.write(f"seed-server: http://{BIND_HOST}:{BIND_PORT} -> s3://{S3_BUCKET}/{S3_KEY}\n")
    ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler).serve_forever()

if __name__ == "__main__":
    main()
