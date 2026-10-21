#!/usr/bin/env python3
"""Local HTTPS stub for Scripts/test_batch.sh.

Serves the captured fixtures under the paths Debug builds use when the config key
foo_component_updater_mac.debug.api_base points here:

  /registry/known_components.json            shared registry
  /repos/JendaT/fb2k-components-mac-suite/releases   GitHub releases of the JendaT suite
  /repos/<other>/releases                    404
  /components/view/foo_abx                   foobar2000.org catalog page
  /components/view/<other>                   catalog "No such component." page (HTTP 200, as the real site)

--mode ratelimit answers every /repos/ request with 403 and x-ratelimit-* headers.
--mode badregistry adds registry entries for foo_jl_vectorscope (owner "a/../b") and foo_jl_scrobble
(source hyv, http url) and records any request for them.
Every request is appended to --log as one JSON object per line.
"""
import argparse
import json
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--fixtures", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--delay", type=float, default=0.0, help="seconds to wait before answering /repos/ requests")
    ap.add_argument("--mode", choices=["normal", "ratelimit", "badregistry"], default="normal")
    args = ap.parse_args()
    fixtures = Path(args.fixtures)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, status, body, ctype="application/json", headers=None):
            data = body if isinstance(body, bytes) else body.encode()
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            with open(args.log, "a") as f:
                f.write(json.dumps({"path": self.path, "ua": self.headers.get("User-Agent", "")}) + "\n")
            path = self.path.split("?")[0]
            if path.startswith("/repos/"):
                if args.delay:
                    time.sleep(args.delay)
                if args.mode == "ratelimit":
                    return self.reply(403, '{"message":"API rate limit exceeded"}', headers={
                        "x-ratelimit-limit": "60", "x-ratelimit-remaining": "0",
                        "x-ratelimit-reset": str(int(time.time()) + 3600)})
                if path == "/repos/JendaT/fb2k-components-mac-suite/releases":
                    return self.reply(200, (fixtures / "jenda_releases.json").read_bytes())
                return self.reply(404, '{"message":"Not Found"}')
            if path == "/registry/known_components.json":
                registry = json.loads((fixtures / "registry.json").read_bytes())
                if args.mode == "badregistry":
                    registry["components"] += [
                        {"dll": "foo_jl_vectorscope", "source": "github", "owner": "a/../b", "repo": "r"},
                        {"dll": "foo_jl_scrobble", "source": "hyv", "url": "http://127.0.0.1/insecure"}]
                return self.reply(200, json.dumps(registry))
            if path == "/components/view/foo_abx":
                return self.reply(200, (fixtures / "catalog_foo_abx.html").read_bytes(), "text/html")
            if path.startswith("/components/view/"):
                return self.reply(200, (fixtures / "catalog_404.html").read_bytes(), "text/html")
            return self.reply(404, "not found", "text/plain")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(args.cert, args.key)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
