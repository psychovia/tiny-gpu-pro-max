#!/usr/bin/env python3
"""Tiny receiver so the Pi can POST diagnostic output to the Azure VM verbatim."""
import http.server, pathlib, datetime

OUT = pathlib.Path("/tmp/claude-1000/-home/ca46c8a9-9c3e-4c0c-8298-2e14dd2d75df/scratchpad/pi_diag")
OUT.mkdir(parents=True, exist_ok=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        stamp = datetime.datetime.now().strftime("%H%M%S")
        name = self.path.strip("/").replace("/", "_") or "diag"
        (OUT / f"{name}-{stamp}.txt").write_bytes(body)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"received\n")

    def do_PUT(self):
        self.do_POST()

    def log_message(self, *a):
        pass


http.server.HTTPServer(("0.0.0.0", 9091), Handler).serve_forever()
