/* A test oracle for http/hpack: libnghttp2's HPACK deflater and inflater, driven from text.
 *
 *   hpack_oracle gen SEED BLOCKS      random header blocks, one field per line "hex(name) hex(value)",
 *                                     blocks ended by a line "--"
 *   hpack_oracle deflate              fields on stdin -> one hex line per block (nghttp2's encoding)
 *   hpack_oracle inflate              hex lines on stdin (one block each) -> fields, as `gen` prints them
 *
 * tests/hpack_interop.sh builds it (when libnghttp2 and its header are installed) and checks http/hpack
 * against it in both directions: nghttp2's encoding decodes to the same fields in Eider, and Eider's
 * encoding decodes to the same fields in nghttp2. */
#include <nghttp2/nghttp2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned long long rng;
static unsigned rnd(void) { rng = rng * 6364136223846793005ULL + 1442695040888963407ULL; return (unsigned)(rng >> 33); }

static void hexout(const unsigned char *p, size_t n) { for (size_t i = 0; i < n; i++) printf("%02x", p[i]); }

static size_t unhex(const char *s, unsigned char *out) {
  size_t n = 0;
  while (s[0] && s[1] && s[0] != '\n' && s[0] != ' ') {
    unsigned v; sscanf(s, "%2x", &v); out[n++] = (unsigned char)v; s += 2;
  }
  return n;
}

static const char *names[] = { ":method", ":path", ":scheme", ":authority", "accept", "content-type", "content-length", "cookie",
  "authorization", "user-agent", "x-request-id", "x-a", "x-b", "grpc-status", "te", "set-cookie", "date", "etag", "vary", "x-long" };
static const char *values[] = { "GET", "POST", "/", "/index.html", "https", "text/html", "application/grpc", "trailers", "gzip, deflate",
  "a=b", "Bearer token", "200", "0", "x" };

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

static int deflate_mode(void) {
  nghttp2_hd_deflater *d;
  if (nghttp2_hd_deflate_new(&d, 4096) != 0) return 1;
  char *line = NULL; size_t cap = 0;
  nghttp2_nv nv[64]; unsigned char *store[64 * 2]; int n = 0, ns = 0;
  while (getline(&line, &cap, stdin) > 0) {
    if (line[0] == '-') {
      size_t len = nghttp2_hd_deflate_bound(d, nv, n);
      unsigned char *buf = malloc(len);
      nghttp2_ssize r = nghttp2_hd_deflate_hd2(d, buf, len, nv, n);
      if (r < 0) return 2;
      hexout(buf, (size_t)r); printf("\n");
      free(buf);
      for (int i = 0; i < ns; i++) free(store[i]);
      n = ns = 0;
      continue;
    }
    unsigned char *nm = malloc(strlen(line)), *vl = malloc(strlen(line));
    size_t nlen = unhex(line, nm);
    char *sp = strchr(line, ' ');
    size_t vlen = unhex(sp + 1, vl);
    nv[n].name = nm; nv[n].namelen = nlen; nv[n].value = vl; nv[n].valuelen = vlen; nv[n].flags = NGHTTP2_NV_FLAG_NONE; n++;
    store[ns++] = nm; store[ns++] = vl;
  }
  return 0;
}

static int inflate_mode(void) {
  nghttp2_hd_inflater *in;
  if (nghttp2_hd_inflate_new(&in) != 0) return 1;
  char *line = NULL; size_t cap = 0;
  while (getline(&line, &cap, stdin) > 0) {
    unsigned char *buf = malloc(strlen(line)); size_t len = unhex(line, buf), pos = 0;
    for (;;) {
      nghttp2_nv nv; int flags = 0;
      nghttp2_ssize r = nghttp2_hd_inflate_hd2(in, &nv, &flags, buf + pos, len - pos, 1);
      if (r < 0) { fprintf(stderr, "nghttp2 inflate error %d\n", (int)r); return 2; }
      pos += (size_t)r;
      if (flags & NGHTTP2_HD_INFLATE_EMIT) { hexout(nv.name, nv.namelen); printf(" "); hexout(nv.value, nv.valuelen); printf("\n"); }
      if (flags & NGHTTP2_HD_INFLATE_FINAL) { nghttp2_hd_inflate_end_headers(in); break; }
      if (!(flags & NGHTTP2_HD_INFLATE_EMIT) && pos >= len) break;
    }
    printf("--\n");
    free(buf);
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 4 && !strcmp(argv[1], "gen")) { gen((unsigned)atoi(argv[2]), atoi(argv[3])); return 0; }
  if (argc >= 2 && !strcmp(argv[1], "deflate")) return deflate_mode();
  if (argc >= 2 && !strcmp(argv[1], "inflate")) return inflate_mode();
  fprintf(stderr, "usage: hpack_oracle gen SEED BLOCKS | deflate | inflate\n");
  return 2;
}
