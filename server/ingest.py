import gzip
import json
from http.server import BaseHTTPRequestHandler


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        # Path check first: anything but /ingest is a 404, and bail early.
        if self.path != "/ingest":
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        # zagent ships gzip-compressed NDJSON (one JSON object per line).
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)

        try:
            for line in body.splitlines():
                if not line.strip():
                    continue
                rec = json.loads(line)  # {"ts", "kind", "msg"}
                if rec.get("kind") == "metric":
                    # `msg` is double-encoded: a JSON string of the Sample.
                    print("metric:", json.loads(rec["msg"]))
                else:
                    print("log:", rec.get("msg", "").rstrip())
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Invalid NDJSON")
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok"}).encode())
