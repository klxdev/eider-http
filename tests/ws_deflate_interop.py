# permessage-deflate against python3's zlib (an independent DEFLATE): a stdlib-only WebSocket client that negotiates
# the extension with the Eider server, sends messages compressed by zlib and inflates what comes back with zlib,
# with and without context takeover. Prints `ok   ws deflate interop: <case>` or `FAIL ...`.
import base64, os, socket, struct, sys, zlib

port = int(sys.argv[1])
fails = 0

def report(name, ok, why=""):
    global fails
    if ok:
        print("ok   ws deflate interop: " + name)
    else:
        fails += 1
        print("FAIL ws deflate interop: " + name + " " + why)

def recv_exact(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError("closed")
        b += c
    return b

def read_frame(s):
    h = recv_exact(s, 2)
    fin, rsv1, op = h[0] & 128, h[0] & 64, h[0] & 15
    n = h[1] & 127
    if n == 126:
        n = struct.unpack(">H", recv_exact(s, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", recv_exact(s, 8))[0]
    return fin, rsv1, op, recv_exact(s, n)

def send_frame(s, rsv1, op, payload):
    key = os.urandom(4)
    n = len(payload)
    head = bytes([128 | (64 if rsv1 else 0) | op])
    if n < 126:
        head += bytes([128 | n])
    elif n < 65536:
        head += bytes([128 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([128 | 127]) + struct.pack(">Q", n)
    s.sendall(head + key + bytes(b ^ key[i % 4] for i, b in enumerate(payload)))

def connect(path, offer):
    s = socket.create_connection(("127.0.0.1", port), timeout=20)
    key = base64.b64encode(os.urandom(16)).decode()
    req = ("GET %s HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: %s\r\n\r\n") % (path, key, offer)
    s.sendall(req.encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += s.recv(1)
    return s, head.decode()

def case(name, path, offer, client_reset, server_reset, expect_ext):
    try:
        s, head = connect(path, offer)
        ext = [l for l in head.split("\r\n") if l.lower().startswith("sec-websocket-extensions")]
        if expect_ext not in (ext[0] if ext else ""):
            report(name, False, "extension header: %r" % ext)
            return
        comp = zlib.compressobj(6, zlib.DEFLATED, -15)
        dec = zlib.decompressobj(-15)
        good = True
        for i in range(30):
            msg = (("zlib says hello %d " % i) * (10 + i)).encode()
            if client_reset:
                comp = zlib.compressobj(6, zlib.DEFLATED, -15)
            if server_reset:
                dec = zlib.decompressobj(-15)
            data = comp.compress(msg) + comp.flush(zlib.Z_SYNC_FLUSH)
            assert data.endswith(b"\x00\x00\xff\xff")
            send_frame(s, True, 1, data[:-4])
            fin, rsv1, op, payload = read_frame(s)
            if not rsv1 or op != 1 or not fin:
                good = False
                break
            back = dec.decompress(payload + b"\x00\x00\xff\xff")
            if back != msg:
                good = False
                break
        # a message we send uncompressed is echoed (compressed or not, by the server's minimum size)
        send_frame(s, False, 1, b"hi")
        fin, rsv1, op, payload = read_frame(s)
        if rsv1:
            payload = (zlib.decompressobj(-15) if server_reset else dec).decompress(payload + b"\x00\x00\xff\xff")
        good = good and payload == b"hi"
        # also: the BFINAL flavour (zlib's Z_FINISH) is understood
        if good and not server_reset:
            c2 = zlib.compressobj(6, zlib.DEFLATED, -15)
            data = c2.compress(b"final block message") + c2.flush(zlib.Z_FINISH)
            send_frame(s, True, 1, data)
            fin, rsv1, op, payload = read_frame(s)
            got = zlib.decompressobj(-15).decompress(payload + b"\x00\x00\xff\xff") if rsv1 else payload
            good = got == b"final block message"
        send_frame(s, False, 8, struct.pack(">H", 1000))
        s.close()
        report(name, good)
    except Exception as e:
        report(name, False, repr(e))

case("context takeover", "/z", "permessage-deflate; client_max_window_bits", False, False, "permessage-deflate")
case("client_no_context_takeover", "/z", "permessage-deflate; client_no_context_takeover", True, False, "client_no_context_takeover")
case("server forces no takeover", "/znt", "permessage-deflate", True, True, "server_no_context_takeover")
sys.exit(1 if fails else 0)
