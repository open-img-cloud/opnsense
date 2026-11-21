#!/usr/bin/env python3
"""Minimal OpenStack metadata service on stdin/stdout, for QEMU guestfwd cmd:.

One HTTP request per process (QEMU spawns one per connection). Serves
$MD_DIR/meta_data.json and $MD_DIR/user_data under /openstack/latest/, and
stores the body of POST /openstack/latest/password in $MD_DIR/password.
"""
import os
import sys

md = os.environ["MD_DIR"]
inp = sys.stdin.buffer
out = sys.stdout.buffer
line = inp.readline().decode("latin-1").strip()
if not line:
    sys.exit(0)
method, path, _ = (line.split(" ") + ["", "", ""])[:3]
length = 0
while True:
    h = inp.readline().decode("latin-1")
    if h in ("\r\n", "\n", ""):
        break
    if h.lower().startswith("content-length:"):
        length = int(h.split(":", 1)[1])
body = inp.read(length) if length else b""
with open(os.path.join(md, "requests.log"), "a") as log:
    log.write(f"{method} {path}\n")


def reply(code, data=b"", reason="OK"):
    out.write(f"HTTP/1.1 {code} {reason}\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n".encode())
    out.write(data)
    out.flush()


files = {"/openstack/latest/meta_data.json": "meta_data.json", "/openstack/latest/user_data": "user_data"}
if method == "GET" and path in files and os.path.exists(os.path.join(md, files[path])):
    reply(200, open(os.path.join(md, files[path]), "rb").read())
elif method == "POST" and path == "/openstack/latest/password":
    open(os.path.join(md, "password"), "wb").write(body)
    reply(200)
else:
    reply(404, b"", "Not Found")
