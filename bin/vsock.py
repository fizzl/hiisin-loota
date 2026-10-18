#!/usr/bin/env python3
"""Host-side client for Firecracker's vsock unix socket.

usage: vsock.py UDS_PATH PORT send   # stream stdin to guest port
       vsock.py UDS_PATH PORT recv   # stream guest port to stdout
       vsock.py UDS_PATH PORT ping   # exit 0 if the guest accepts on PORT
       vsock.py UDS_PATH PORT exec   # send stdin + terminator line, then stream the reply
       vsock.py UDS_PATH PORT raw    # like exec but the caller supplies the terminator (and any data after it)
Firecracker does not forward a host half-close as a guest half-close, so "exec"
ends the request with a terminator line instead of shutdown(SHUT_WR).
Firecracker protocol: write "CONNECT <port>\\n", read "OK <port>\\n", then raw bytes.
"""
import socket, sys

def main():
    uds, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(uds)
    s.sendall(f"CONNECT {port}\n".encode())
    buf = b""
    while not buf.endswith(b"\n"):
        c = s.recv(1)
        if not c:
            sys.exit(2)
        buf += c
    if not buf.startswith(b"OK"):
        sys.exit(3)
    s.settimeout(None)
    if mode == "ping":
        return
    if mode in ("send", "exec", "raw"):
        f = sys.stdin.buffer
        try:
            while chunk := f.read(1 << 16):
                s.sendall(chunk)
            if mode == "exec":
                s.sendall(b"\n__HIISIN_LOOTA_EOF__\n")
            elif mode == "send":
                s.shutdown(socket.SHUT_WR)
        except BrokenPipeError:
            pass  # guest finished early (e.g. a data-phase script failed); still collect its reply
        out = sys.stdout.buffer
        while chunk := s.recv(1 << 16):  # for "send" this just waits for guest close
            if mode != "send":
                out.write(chunk); out.flush()
    elif mode == "recv":
        out = sys.stdout.buffer
        while chunk := s.recv(1 << 16):
            out.write(chunk)
        out.flush()
    else:
        sys.exit(f"bad mode {mode}")

if __name__ == "__main__":
    main()
