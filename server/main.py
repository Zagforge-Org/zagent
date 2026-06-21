from http.server import HTTPServer

from ingest import Handler

server = HTTPServer(("localhost", 8080), Handler)

print("Listening on http://localhost:8080")
server.serve_forever()
