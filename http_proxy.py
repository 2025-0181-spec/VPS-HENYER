#!/usr/bin/env python3
"""
VPS-HENYER — Proxy HTTP/WebSocket para SSH
Soporta: CONNECT, WebSocket (GET+Upgrade), HTTP generico
Compatible: HTTP Custom, HTTP Injector, NapsternetV
"""
import socket, threading, select, sys, datetime

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8880
SSH_HOST    = "127.0.0.1"
SSH_PORT    = int(sys.argv[2]) if len(sys.argv) > 2 else 80
BUFFER      = 65536

def log(msg):
    print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)

def bridge(src, dst):
    try:
        while True:
            r, _, _ = select.select([src, dst], [], [], 120)
            if not r:
                break
            for s in r:
                try:
                    data = s.recv(BUFFER)
                except:
                    return
                if not data:
                    return
                other = dst if s is src else src
                try:
                    other.sendall(data)
                except:
                    return
    except:
        pass
    finally:
        for s in (src, dst):
            try: s.close()
            except: pass

def handle_client(client):
    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    try:
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = client.recv(BUFFER)
            if not chunk:
                return
            raw += chunk
            if len(raw) > 65536:
                return

        header_part = raw[:raw.find(b"\r\n\r\n")].decode("utf-8", errors="ignore")
        first_line  = header_part.split("\r\n")[0] if header_part else ""
        is_websocket = "upgrade: websocket" in header_part.lower()
        is_connect   = first_line.upper().startswith("CONNECT")

        ssh = socket.create_connection((SSH_HOST, SSH_PORT), timeout=10)
        ssh.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        if is_connect:
            client.sendall(b"HTTP/1.1 200 Connection Established\r\nProxy-agent: VPS-HENYER\r\n\r\n")
            log(f"[CONNECT] -> SSH:{SSH_PORT}")
        elif is_websocket:
            client.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\n"
                b"Connection: Upgrade\r\n"
                b"\r\n"
            )
            log(f"[WS] -> SSH:{SSH_PORT}")
        else:
            client.sendall(b"HTTP/1.1 200 OK\r\nProxy-agent: VPS-HENYER\r\n\r\n")
            log(f"[HTTP] {first_line[:60]} -> SSH:{SSH_PORT}")

        tail = raw[raw.find(b"\r\n\r\n") + 4:]
        if tail:
            ssh.sendall(tail)

        threading.Thread(target=bridge, args=(client, ssh), daemon=True).start()

    except Exception as e:
        log(f"[ERR] {e}")
        try: client.close()
        except: pass

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(500)
    log(f"VPS-HENYER proxy :{LISTEN_PORT} -> SSH:{SSH_PORT}")
    while True:
        try:
            client, _ = srv.accept()
            threading.Thread(target=handle_client, args=(client,), daemon=True).start()
        except KeyboardInterrupt:
            break
        except Exception as e:
            log(f"[ACCEPT ERR] {e}")

if __name__ == "__main__":
    main()
