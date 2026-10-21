"""The Luxeia add-on's web server (run by run.sh).

Serves the dashboard to Home Assistant's ingress proxy, and nobody else.
It replaced BusyBox's httpd so it can say how long phones may keep each
file: on 4G through remote access, a phone asking again about each of the
app's ~120 files on every open (six at a time, the most Home Assistant
allows) took 10 to 30 seconds.

- A file asked for with this build's ?v= (every module, stylesheet and
  font: scripts/package-release.sh stamps them) never changes, so phones
  keep it until the next build (Cache-Control: immutable) and don't ask
  again. Asked for with another build's ?v=, it isn't kept at all, so an
  old address can't hold this build's file.
- Everything else (index.html, build.json, update-status.json, the
  waiting page) is checked every time (no-cache, with Last-Modified, so an
  unchanged file is a short "not modified").
- Home Assistant compresses what passes through ingress itself (it strips
  Accept-Encoding on the way in), so nothing is compressed here.

"Check for updates" in the app posts to check-now: that leaves a note
(the asked file) for run.sh, which checks within a few seconds. Anyone
signed in can ask; a check only ever installs a build Luxeia approved.

Usage: python3 serve.py <port> <allowed address> <build folder> <waiting folder> <asked file>
The build folder is looked up on every request, so a build swapped in by
the updater is served at once. The waiting folder is used until a build
arrives. Standard library only.
"""

import email.utils
import http.server
import json
import os
import socketserver
import sys
import time
import urllib.parse

TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.woff2': 'font/woff2',
    '.txt': 'text/plain; charset=utf-8',
}
KEEP = 'private, max-age=31536000, immutable'
CHECK = 'no-cache'


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        # A phone that gave up mid-way (a train going into a tunnel) is normal
        if not isinstance(sys.exc_info()[1], ConnectionError):
            super().handle_error(request, client_address)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'  # keep-alive: ingress reuses its connections
    server_version = 'Luxeia'
    sys_version = ''

    def log_message(self, *args):
        pass  # one line per file would bury the add-on's own log

    def answer(self, status, body=b'', headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        if self.client_address[0] != ALLOWED:
            return self.answer(403, b'Forbidden', [('Content-Type', 'text/plain')])
        length = int(self.headers.get('Content-Length') or 0)
        if length > 4096:
            self.close_connection = True  # not reading all of it, so this connection can't be reused
        elif length:
            self.rfile.read(length)
        if urllib.parse.urlsplit(self.path).path.rstrip('/') != '/check-now':
            return self.answer(404, b'Not found', [('Content-Type', 'text/plain')])
        with open(ASKED, 'w') as f:
            f.write(str(time.time()))
        self.answer(202, b'{"asked": true}', [('Content-Type', 'application/json'), ('Cache-Control', 'no-store')])

    def do_GET(self):
        if self.client_address[0] != ALLOWED:
            return self.answer(403, b'Forbidden', [('Content-Type', 'text/plain')])
        root = LIVE if os.path.isfile(os.path.join(LIVE, 'index.html')) else WAITING
        url = urllib.parse.urlsplit(self.path)
        rel = urllib.parse.unquote(url.path).lstrip('/')
        if rel == '' or rel.endswith('/'):
            rel += 'index.html'
        real_root = os.path.realpath(root)
        file = os.path.realpath(os.path.join(real_root, rel))
        # Nothing outside the build (no "..", no links out of it), and no folder listings
        if not file.startswith(real_root + os.sep) or not os.path.isfile(file):
            return self.answer(404, b'Not found', [('Content-Type', 'text/plain')])

        stat = os.stat(file)
        modified = email.utils.formatdate(stat.st_mtime, usegmt=True)
        version = urllib.parse.parse_qs(url.query).get('v', [None])[0]
        if version is None:
            cache = CHECK
        elif version == build_id(root):
            cache = KEEP
        else:
            cache = 'no-store'
        headers = [('Content-Type', TYPES.get(os.path.splitext(file)[1], 'application/octet-stream')),
                   ('Cache-Control', cache), ('Last-Modified', modified)]
        if cache == CHECK and self.headers.get('If-Modified-Since') == modified:
            return self.answer(304, headers=headers[1:])
        with open(file, 'rb') as f:
            body = f.read()
        self.answer(200, body, headers)


def build_id(root):
    """This build's id, from its build.json (read again only when it changes)."""
    path = os.path.join(root, 'build.json')
    try:
        stamp = os.stat(path).st_mtime_ns, path
        if _build.get('stamp') != stamp:
            with open(path) as f:
                _build.update(stamp=stamp, id=json.load(f).get('version'))
        return _build.get('id')
    except (OSError, ValueError):
        return None


_build = {}

if __name__ == '__main__':
    PORT, ALLOWED, LIVE, WAITING, ASKED = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
    Server(('', PORT), Handler).serve_forever()
