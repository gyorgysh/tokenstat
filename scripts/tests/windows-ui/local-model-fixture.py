# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Serve a disposable local model catalog for the Windows terminal UI check."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class OllamaFixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/api/tags":
            self.send_error(404)
            return
        body = json.dumps({"models": [{"name": "fixture:latest", "size": 128}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    with HTTPServer(("127.0.0.1", 0), OllamaFixture) as server:
        port_file = Path(sys.argv[1])
        staged = port_file.with_suffix(".tmp")
        staged.write_text(str(server.server_port), encoding="ascii")
        staged.replace(port_file)
        server.serve_forever()
