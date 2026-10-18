#!/usr/bin/env python3
"""Credential broker for the hiisin-loota guest. Stdlib only.

usage: cred-broker.py --bind IP --port N --creds FILE --log FILE [--upstream HOST] [--peer IP]

The guest runs Claude Code with ANTHROPIC_BASE_URL=http://IP:N and a placeholder
ANTHROPIC_AUTH_TOKEN, so no credential ever enters the VM. This process
receives those plain-HTTP requests on the tap address, swaps the Authorization
header for the host's subscription access token (re-read from the credentials
file on every request, so a refresh done by the host's Claude Code is picked
up), adds the OAuth beta flag the subscription endpoint expects, and forwards
the request to the upstream API over TLS, streaming the response back.

Only the guest address (--peer) is served. The token is never logged. The
broker does not refresh the token itself: if the host file holds an expired
token and nothing on the host refreshes it, requests fail upstream with 401
and the log says so.
"""
import argparse, http.client, json, socket, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OAUTH_BETA = "oauth-2025-04-20"
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "proxy-connection",
       "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length",
       "authorization", "x-api-key"}
UPSTREAM_TIMEOUT = 600

class Creds:
    def __init__(self, path):
        self.path = path
    def token(self):
        d = json.load(open(self.path, encoding="utf-8")).get("claudeAiOauth") or {}
        tok, exp = d.get("accessToken"), d.get("expiresAt")
        if not tok:
            raise RuntimeError("no claudeAiOauth.accessToken in credentials file")
        return tok, (exp / 1000 - time.time()) if exp else None

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "hiisin-loota-broker"
    def log_message(self, *a):  # silence default stderr logging
        pass
    def _body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            out = b""
            while True:
                n = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if n == 0:
                    self.rfile.readline(); return out
                out += self.rfile.read(n); self.rfile.readline()
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def _handle(self):
        srv, t0 = self.server, time.time()
        if self.client_address[0] != srv.peer:
            self.send_error(403, "not the guest"); return
        try:
            body = self._body()
            tok, ttl = srv.creds.token()
            if ttl is not None and ttl < 0:
                srv.log(f"WARN host access token expired {int(-ttl)}s ago; refresh it on the host (run claude)")
            hdrs = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
            hdrs["Host"] = srv.upstream
            hdrs["Authorization"] = "Bearer " + tok
            betas = [b.strip() for b in hdrs.get("anthropic-beta", "").split(",") if b.strip()]
            if OAUTH_BETA not in betas:
                betas.append(OAUTH_BETA)
            hdrs["anthropic-beta"] = ",".join(betas)
            hdrs["Connection"] = "close"
            c = http.client.HTTPSConnection(srv.upstream, 443, timeout=UPSTREAM_TIMEOUT)
            c.request(self.command, self.path, body=body, headers=hdrs)
            r = c.getresponse()
        except Exception as e:  # noqa: BLE001
            srv.log(f"ERR {self.command} {self.path} {type(e).__name__}: {e}")
            try: self.send_error(502, "broker upstream failure")
            except Exception: pass
            return
        self.send_response(r.status, r.reason)
        for k, v in r.getheaders():
            if k.lower() not in ("transfer-encoding", "content-length", "connection"):
                self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked"); self.send_header("Connection", "close")
        self.end_headers()
        n = 0
        try:
            while True:
                chunk = r.read(1 << 14)
                if not chunk: break
                n += len(chunk)
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk)); self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            c.close(); self.close_connection = True
        srv.log(f"{r.status} {self.command} {self.path} in={len(body)} out={n} {time.time()-t0:.2f}s")
    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = _handle

class Server(ThreadingHTTPServer):
    daemon_threads = True; allow_reuse_address = True
    def __init__(self, addr, creds, upstream, peer, logf):
        super().__init__(addr, Handler)
        self.creds, self.upstream, self.peer, self.logf, self.lock = creds, upstream, peer, logf, threading.Lock()
    def log(self, line):
        with self.lock:
            self.logf.write(time.strftime("%H:%M:%S ") + line + "\n"); self.logf.flush()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", required=True); ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--creds", required=True); ap.add_argument("--log", required=True)
    ap.add_argument("--upstream", default="api.anthropic.com"); ap.add_argument("--peer", required=True)
    a = ap.parse_args()
    creds = Creds(a.creds); creds.token()  # fail early if the host is not logged in
    srv = Server((a.bind, a.port), creds, a.upstream, a.peer, open(a.log, "a", encoding="utf-8"))
    srv.log(f"broker up on {a.bind}:{a.port} -> https://{a.upstream} for peer {a.peer}")
    try: srv.serve_forever()
    except KeyboardInterrupt: pass

if __name__ == "__main__":
    main()
