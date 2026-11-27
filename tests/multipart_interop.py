# Python's stdlib against the Eider server of tests/multipart_interop_server.ei (tests/multipart_interop.sh):
#   - email/http.client build multipart/form-data bodies (MIMEMultipart, with RFC 2231 filenames) that the
#     Eider parser reads, and
#   - email.parser reads a body the Eider builder wrote (GET /sample).
# Prints `ok   multipart interop: <case>` or `FAIL ...`; exits 1 on a failure.
import email.policy
import http.client
import io
import sys
from email.generator import BytesGenerator
from email.mime.base import MIMEBase
from email.mime.multipart import MIMEMultipart
from email.parser import BytesParser

port = int(sys.argv[1])
fails = 0


def check(name, got, want):
    global fails
    if got == want:
        print("ok   multipart interop: " + name)
    else:
        fails += 1
        print("FAIL multipart interop: " + name)
        print("    want: %.300r" % (want,))
        print("    got:  %.300r" % (got,))


def build(parts, boundary=None):
    m = MIMEMultipart("form-data", boundary=boundary)
    del m["MIME-Version"]
    for name, data, filename, ct in parts:
        p = MIMEBase(*ct.split("/"))
        del p["MIME-Version"]
        p.set_payload(data.encode() if isinstance(data, str) else data)
        if filename is None:
            p.add_header("Content-Disposition", "form-data", name=name)
        else:
            p.add_header("Content-Disposition", "form-data", name=name, filename=("utf-8", "", filename))
        m.attach(p)
    fp = io.BytesIO()
    BytesGenerator(fp, policy=email.policy.HTTP.clone(max_line_length=0)).flatten(m)
    head, body = fp.getvalue().split(b"\r\n\r\n", 1)
    return m["Content-Type"], body


def post(ct, body):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    c.request("POST", "/upload", body=body, headers={"Content-Type": ct})
    r = c.getresponse()
    return r.status, r.read().decode("utf-8", "replace")


def summary(name, filename, ct, data):
    return "%s|%s|%s|%d|%d" % (name, filename or "-", ct, len(data), sum(data) % 1000003)


binary = bytes(b for b in range(256) if b not in (10, 13)) * 40 + b"--x--"
parts = [
    ("title", "hello wörld", None, "text/plain"),
    ("doc", "line one\r\n--not-a-delimiter\r\nline two", "notes.txt", "text/plain"),
    ("blob", binary, "café €.bin", "application/octet-stream"),
    ("empty", "", None, "text/plain"),
]
ct, body = build(parts)
status, text = post(ct, body)
want = "\n".join([
    summary("title", None, "text/plain", "hello wörld".encode()),
    summary("doc", "notes.txt", "text/plain", b"line one\r\n--not-a-delimiter\r\nline two"),
    summary("blob", "café €.bin", "application/octet-stream", binary),
    summary("empty", None, "text/plain", b""),
]) + "\n"
check("a body made by email.mime (quoted boundary with =, filename*, binary)", (status, text), (200, want))

ct, body = build([("a", "x", None, "text/plain")], boundary="simple-boundary-123")
check("a plain boundary", post(ct, body), (200, summary("a", None, "text/plain", b"x") + "\n"))

big = bytes(range(32, 127)) * 20000
ct, body = build([("big", big, "big.bin", "application/octet-stream")])
check("a 1.9 MB part", post(ct, body), (200, summary("big", "big.bin", "application/octet-stream", big) + "\n"))

# a cut body is a 400 problem+json
status, text = post(ct, body[:1000])
check("a truncated body is 400", status, 400)

# the other direction: Python parses what the Eider builder wrote
c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
c.request("GET", "/sample")
r = c.getresponse()
sct = r.getheader("Content-Type")
sbody = r.read()
msg = BytesParser(policy=email.policy.HTTP).parsebytes(b"Content-Type: " + sct.encode() + b"\r\n\r\n" + sbody)
got = []
for p in msg.iter_parts():
    got.append((p.get_param("name", header="content-disposition"), p.get_filename(), p.get_content_type(), p.get_payload(decode=True)))
want = [
    ("title", None, "text/plain", "héllo\r\nworld".encode()),
    ("notes", "notes.txt", "text/plain", b"one\r\n--not-a-boundary\r\ntwo"),
    ("blob", "café \"q\".bin", "application/octet-stream", bytes(i % 256 for i in range(3000))),
    ("empty", None, "text/plain", b""),
]
check("email.parser reads the builder's body", got, want)
sys.exit(1 if fails else 0)
