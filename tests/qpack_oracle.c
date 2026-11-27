/* A test oracle for http/qpack: libnghttp3's QPACK encoder and decoder, driven from text.
 *
 *   qpack_oracle static               the 99 static table entries as nghttp3 decodes them: "i name: value"
 *   qpack_oracle gen SEED BLOCKS      random field lists, one field per line "hex(name) hex(value)", blocks ended by "--"
 *   qpack_oracle encode CAP BLOCKED   those fields on stdin -> per block "E hex" (its encoder stream bytes, maybe empty)
 *                                     and "P hex" (the field section); the decoder acknowledges nothing
 *   qpack_oracle decode CAP BLOCKED   "E hex" and "P hex" lines on stdin (the P lines are streams 0, 4, 8, ...) -> the fields
 *                                     of each section as `gen` prints them, then "--"; "BLOCKED" or "ERROR n" instead on failure
 *
 * tests/qpack_interop.sh builds it (it needs libnghttp3 only, not its header: the prototypes are declared here) and checks
 * http/qpack against it in both directions. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
typedef struct nghttp3_mem nghttp3_mem;
typedef struct nghttp3_qpack_encoder nghttp3_qpack_encoder;
typedef struct nghttp3_qpack_decoder nghttp3_qpack_decoder;
typedef struct nghttp3_qpack_stream_context nghttp3_qpack_stream_context;
typedef struct nghttp3_rcbuf nghttp3_rcbuf;
typedef ptrdiff_t nghttp3_ssize;
typedef struct { uint8_t *begin, *end, *pos, *last; } nghttp3_buf;
typedef struct { uint8_t *base; size_t len; } nghttp3_vec;
typedef struct { nghttp3_rcbuf *name; nghttp3_rcbuf *value; uint8_t flags; } nghttp3_qpack_nv;
typedef struct { uint8_t *name; uint8_t *value; size_t namelen; size_t valuelen; uint8_t flags; } nghttp3_nv;
const nghttp3_mem *nghttp3_mem_default(void);
int nghttp3_qpack_encoder_new(nghttp3_qpack_encoder **, size_t, const nghttp3_mem *);
void nghttp3_qpack_encoder_set_max_dtable_capacity(nghttp3_qpack_encoder *, size_t);
void nghttp3_qpack_encoder_set_max_blocked_streams(nghttp3_qpack_encoder *, size_t);
nghttp3_ssize nghttp3_qpack_encoder_encode(nghttp3_qpack_encoder *, nghttp3_buf *, nghttp3_buf *, nghttp3_buf *, int64_t, const nghttp3_nv *, size_t);
int nghttp3_qpack_decoder_new(nghttp3_qpack_decoder **, size_t, size_t, const nghttp3_mem *);
nghttp3_ssize nghttp3_qpack_decoder_read_encoder(nghttp3_qpack_decoder *, const uint8_t *, size_t);
nghttp3_ssize nghttp3_qpack_decoder_read_request(nghttp3_qpack_decoder *, nghttp3_qpack_stream_context *, nghttp3_qpack_nv *, uint8_t *, const uint8_t *, size_t, int);
int nghttp3_qpack_stream_context_new(nghttp3_qpack_stream_context **, int64_t, const nghttp3_mem *);
nghttp3_vec nghttp3_rcbuf_get_buf(const nghttp3_rcbuf *);
void nghttp3_rcbuf_decref(nghttp3_rcbuf *);

static void hexout(const uint8_t *p, size_t n) { for (size_t i = 0; i < n; i++) printf("%02x", p[i]); }
static size_t unhex(const char *s, uint8_t *out) {
  size_t n = 0;
  while (s[0] && s[1] && s[0] != '\n' && s[0] != ' ') { unsigned v; sscanf(s, "%2x", &v); out[n++] = (uint8_t)v; s += 2; }
  return n;
}


static unsigned long long rng;
static unsigned rnd(void) { rng = rng * 6364136223846793005ULL + 1442695040888963407ULL; return (unsigned)(rng >> 33); }

static const char *names[] = { ":method", ":path", ":scheme", ":authority", "accept", "content-type", "content-length", "cookie",
  "authorization", "user-agent", "x-request-id", "x-a", "x-b", "grpc-status", "te", "set-cookie", "date", "etag", "vary", "x-long" };
static const char *values[] = { "GET", "POST", "/", "/index.html", "https", "text/html", "application/grpc", "trailers", "gzip, deflate",
  "a=b", "Bearer token", "200", "0", "x", "max-age=0", "no-cache" };

static void gen(unsigned seed, int blocks) {
  rng = seed;
  for (int b = 0; b < blocks; b++) {
    int n = 1 + rnd() % 8;
    for (int i = 0; i < n; i++) {
      unsigned char name[64], val[400];
      size_t nl, vl;
      unsigned k = rnd() % 4;
      if (k == 0) { nl = 1 + rnd() % 20; for (size_t j = 0; j < nl; j++) name[j] = 'a' + rnd() % 26; }
      else { const char *s = names[rnd() % (sizeof names / sizeof *names)]; nl = strlen(s); memcpy(name, s, nl); }
      k = rnd() % 5;
      if (k == 0) { vl = rnd() % 300; for (size_t j = 0; j < vl; j++) val[j] = (unsigned char)rnd(); }
      else if (k == 1) { vl = rnd() % 40; for (size_t j = 0; j < vl; j++) val[j] = 32 + rnd() % 95; }
      else { const char *s = values[rnd() % (sizeof values / sizeof *values)]; vl = strlen(s); memcpy(val, s, vl); }
      hexout(name, nl); printf(" "); hexout(val, vl); printf("\n");
    }
    printf("--\n");
  }
}

static int do_static(void) {
  nghttp3_qpack_decoder *dec;
  nghttp3_qpack_decoder_new(&dec, 0, 0, nghttp3_mem_default());
  for (int i = 0; i < 99; i++) {
    uint8_t sec[8]; size_t n = 0;
    sec[n++] = 0; sec[n++] = 0;
    if (i < 63) sec[n++] = 0xc0 | i; else { sec[n++] = 0xff; sec[n++] = i - 63; }
    nghttp3_qpack_stream_context *sc; nghttp3_qpack_stream_context_new(&sc, i * 4, nghttp3_mem_default());
    nghttp3_qpack_nv nv; uint8_t fl = 0;
    nghttp3_ssize r = nghttp3_qpack_decoder_read_request(dec, sc, &nv, &fl, sec, n, 1);
    if (r < 0 || !(fl & 1)) { printf("%d ERROR\n", i); continue; }
    nghttp3_vec a = nghttp3_rcbuf_get_buf(nv.name), b = nghttp3_rcbuf_get_buf(nv.value);
    printf("%d %.*s: %.*s\n", i, (int)a.len, a.base, (int)b.len, b.base);
  }
  return 0;
}

static int do_decode(size_t cap, size_t blocked) {
  nghttp3_qpack_decoder *dec;
  nghttp3_qpack_decoder_new(&dec, cap, blocked, nghttp3_mem_default());
  char *line = NULL; size_t lcap = 0;
  uint8_t *buf = malloc(1 << 20);
  long stream = 0;
  while (getline(&line, &lcap, stdin) > 0) {
    if (line[0] == 'E') {
      size_t n = unhex(line + 2, buf);
      nghttp3_ssize r = nghttp3_qpack_decoder_read_encoder(dec, buf, n);
      if (r < 0) { printf("ERROR %zd\n", (long)r); return 1; }
    } else if (line[0] == 'P') {
      size_t n = unhex(line + 2, buf), at = 0;
      nghttp3_qpack_stream_context *sc; nghttp3_qpack_stream_context_new(&sc, stream, nghttp3_mem_default());
      stream += 4;
      for (;;) {
        nghttp3_qpack_nv nv; uint8_t fl = 0;
        nghttp3_ssize r = nghttp3_qpack_decoder_read_request(dec, sc, &nv, &fl, buf + at, n - at, 1);
        if (r < 0) { printf("ERROR %zd\n", (long)r); return 1; }
        at += r;
        if (fl & 4) { printf("BLOCKED\n"); return 1; }
        if (fl & 1) {
          nghttp3_vec a = nghttp3_rcbuf_get_buf(nv.name), b = nghttp3_rcbuf_get_buf(nv.value);
          hexout(a.base, a.len); printf(" "); hexout(b.base, b.len); printf("\n");
          nghttp3_rcbuf_decref(nv.name); nghttp3_rcbuf_decref(nv.value);
        }
        if (fl & 2) break;
        if (!(fl & 1) && r == 0) break;
      }
      printf("--\n");
    }
  }
  return 0;
}

static int do_encode(size_t cap, size_t blocked) {
  nghttp3_qpack_encoder *enc;
  nghttp3_qpack_encoder_new(&enc, cap, nghttp3_mem_default());
  nghttp3_qpack_encoder_set_max_dtable_capacity(enc, cap);
  nghttp3_qpack_encoder_set_max_blocked_streams(enc, blocked);
  char *line = NULL; size_t lcap = 0;
  nghttp3_nv nva[256]; int nn = 0; long stream = 0;
  static uint8_t pb[1 << 20], rb[1 << 20], eb[1 << 20];
  while (getline(&line, &lcap, stdin) > 0) {
    if (line[0] == '-') {
      nghttp3_buf p, r, e;
      p.begin = p.pos = p.last = pb; p.end = pb + sizeof pb;
      r.begin = r.pos = r.last = rb; r.end = rb + sizeof rb;
      e.begin = e.pos = e.last = eb; e.end = eb + sizeof eb;
      nghttp3_ssize rv = nghttp3_qpack_encoder_encode(enc, &p, &r, &e, stream, nva, nn);
      if (rv < 0) { printf("ERROR %zd\n", (long)rv); return 1; }
      stream += 4;
      printf("E "); hexout(e.pos, e.last - e.pos); printf("\n");
      printf("P "); hexout(p.pos, p.last - p.pos); hexout(r.pos, r.last - r.pos); printf("\n");
      nn = 0;
    } else {
      uint8_t *nm = malloc(strlen(line)), *vl = malloc(strlen(line));
      size_t nlen = unhex(line, nm);
      char *sp = strchr(line, ' ');
      size_t vlen = unhex(sp + 1, vl);
      nva[nn].name = nm; nva[nn].namelen = nlen; nva[nn].value = vl; nva[nn].valuelen = vlen; nva[nn].flags = 0; nn++;
    }
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 2 && !strcmp(argv[1], "static")) return do_static();
  if (argc >= 4 && !strcmp(argv[1], "gen")) { gen((unsigned)atoi(argv[2]), atoi(argv[3])); return 0; }
  if (argc >= 4 && !strcmp(argv[1], "decode")) return do_decode(atol(argv[2]), atol(argv[3]));
  if (argc >= 4 && !strcmp(argv[1], "encode")) return do_encode(atol(argv[2]), atol(argv[3]));
  fprintf(stderr, "usage: qpack_oracle static | gen SEED BLOCKS | encode CAP BLOCKED | decode CAP BLOCKED\n");
  return 2;
}
