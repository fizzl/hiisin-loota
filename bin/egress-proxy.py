#!/usr/bin/env python3
"""Host-side egress proxy for the hiisin-loota guest. Stdlib only.

usage: egress-proxy.py --bind IP --port N --allow FILE --log FILE [--log-only]

Speaks HTTP CONNECT (TLS tunnels) and absolute-URI plain HTTP. The guest has no
route except to this proxy and no DNS, so every outbound connection shows up
here with a hostname. Policy, in order:
  1. port must be 443 for CONNECT or 80 for plain HTTP unless the allow entry
     names a port (host:port)
  2. hostname must match an allow entry: exact "host", or ".suffix" for any
     subdomain (".github.com" also matches "github.com")
  3. IP literals are refused; the resolved addresses must all be public
     (no loopback, link-local, RFC1918, or the tap subnet) as a rebinding guard
Denied requests get a 403 naming the host. --log-only allows everything but
still logs verdicts, for discovering what a workload needs.
Allow file: one entry per line, '#' comments. SIGHUP reloads it.
"""
import argparse, ipaddress, select, signal, socket, sys, threading, time

CONNECT_TIMEOUT = 10
IDLE_TIMEOUT = 300
PRIVATE_NETS = [ipaddress.ip_network(n) for n in (
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
    "::1/128", "fc00::/7", "fe80::/10", "ff00::/8")]

class Policy:
    def __init__(self, path, log_only):
        self.path, self.log_only, self.lock = path, log_only, threading.Lock()
        self.load()
    def load(self):
        exact, suffix = {}, {}
        for raw in open(self.path, encoding="utf-8"):
            e = raw.split("#", 1)[0].strip().lower()
            if not e:
                continue
            host, _, port = e.rpartition(":") if ":" in e else (e, "", "")
            port = int(port) if port else None
            (suffix if host.startswith(".") else exact)[host.lstrip(".") if host.startswith(".") else host] = port
        with self.lock:
            self.exact, self.suffix = exact, suffix
    def check(self, host, port, default_port):
        host = host.lower().rstrip(".")
        if not host:
            return "empty host"
        try:
            ipaddress.ip_address(host.strip("[]"))
            return "ip literal"
        except ValueError:
            pass
        with self.lock:
            exact, suffix = self.exact, self.suffix
        allowed_port = None; hit = False
        if host in exact:
            hit, allowed_port = True, exact[host]
        else:
            for suf, p in suffix.items():
                if host == suf or host.endswith("." + suf):
                    hit, allowed_port = True, p; break
        if not hit:
            return "host not in allowlist"
        if port != (allowed_port if allowed_port is not None else default_port):
            return f"port {port} not allowed"
        try:
            infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        except socket.gaierror as e:
            return f"resolve failed: {e}"
        for info in infos:
            a = ipaddress.ip_address(info[4][0])
            if any(a in n for n in PRIVATE_NETS):
                return f"resolves to non-public address {a}"
        return None  # allowed

def log(fh, *parts):
    line = time.strftime("%Y-%m-%dT%H:%M:%S") + " " + " ".join(str(p) for p in parts) + "\n"
    fh.write(line); fh.flush()

def read_head(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        c = conn.recv(65536)
        if not c:
            return None
        buf += c
        if len(buf) > 65536:
            return None
    return buf

def relay(a, b):
    socks = [a, b]
    while True:
        r, _, x = select.select(socks, [], socks, IDLE_TIMEOUT)
        if x or not r:
            return
        for s in r:
            try:
                data = s.recv(65536)
            except OSError:
                return
            if not data:
                return
            (b if s is a else a).sendall(data)

def handle(conn, peer, policy, logfh):
    try:
        conn.settimeout(30)
        head = read_head(conn)
        if not head:
            return
        line = head.split(b"\r\n", 1)[0].decode("latin-1")
        try:
            method, target, _ = line.split(" ", 2)
        except ValueError:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"); return
        if method == "CONNECT":
            host, _, port = target.rpartition(":")
            port = int(port) if port.isdigit() else 443
            default = 443
        else:
            if not target.startswith("http://"):
                conn.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"); return
            hostport = target[7:].split("/", 1)[0]
            host, _, port = hostport.rpartition(":") if ":" in hostport else (hostport, "", "")
            port = int(port) if port.isdigit() else 80
            default = 80
        reason = policy.check(host, port, default)
        verdict = "ALLOW" if reason is None else ("ALLOW(log-only)" if policy.log_only else "DENY")
        log(logfh, verdict, method, f"{host}:{port}", reason or "")
        if verdict == "DENY":
            body = f"hiisin-loota egress: {host}:{port} denied ({reason})\n".encode()
            conn.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: "
                         + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
            return
        try:
            up = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
        except OSError as e:
            log(logfh, "UPSTREAM-FAIL", f"{host}:{port}", e)
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return
        up.settimeout(None); conn.settimeout(None)
        with up:
            if method == "CONNECT":
                conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            else:
                # Plain HTTP: forward the request with an origin-form target, no keep-alive.
                rest = head.split(b"\r\n", 1)[1]
                path = "/" + target[7:].split("/", 1)[1] if "/" in target[7:] else "/"
                hdrs = [h for h in rest.split(b"\r\n") if h and not h.lower().startswith((b"proxy-connection:", b"connection:"))]
                up.sendall(f"{method} {path} HTTP/1.1\r\n".encode() + b"\r\n".join(hdrs) + b"\r\nConnection: close\r\n\r\n")
            relay(conn, up)
    except Exception as e:  # noqa: BLE001
        log(logfh, "ERROR", peer, repr(e))
    finally:
        try: conn.close()
        except OSError: pass

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", required=True); ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--allow", required=True); ap.add_argument("--log", required=True)
    ap.add_argument("--log-only", action="store_true")
    a = ap.parse_args()
    policy = Policy(a.allow, a.log_only)
    logfh = open(a.log, "a", encoding="utf-8")
    signal.signal(signal.SIGHUP, lambda *_: (policy.load(), log(logfh, "RELOAD", a.allow)))
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.bind, a.port)); srv.listen(64)
    log(logfh, "START", f"{a.bind}:{a.port}", "log-only" if a.log_only else "enforcing", a.allow)
    while True:
        try:
            conn, peer = srv.accept()
        except InterruptedError:
            continue
        threading.Thread(target=handle, args=(conn, peer[0], policy, logfh), daemon=True).start()

if __name__ == "__main__":
    main()
