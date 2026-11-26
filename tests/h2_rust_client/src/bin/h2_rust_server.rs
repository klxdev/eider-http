// An HTTP/2 server (the `h2` crate) for tests/h2_interop_client.ei, prior-knowledge h2c:
//   h2_rust_server           prints `listening <port>`
// POST /echo: the body upper-cased, then the trailer x-len. POST /bidi: every chunk answered at once as `echo:<chunk>`,
// then the trailer x-chunks. POST /sum: the sum of the body bytes (a 4 MiB upload through the flow-control windows).
// GET /big: 1 MiB. GET /status/N: an empty response with status N. Anything else: 404.
use bytes::Bytes;
use h2::server;
use http::{HeaderMap, HeaderValue, Response, StatusCode};

async fn handle(req: http::Request<h2::RecvStream>, mut respond: h2::server::SendResponse<Bytes>) {
    let path = req.uri().path().to_string();
    let mut body = req.into_body();
    if path == "/bidi" {
        let resp = Response::builder().status(200).body(()).unwrap();
        let mut send = respond.send_response(resp, false).unwrap();
        let mut n = 0u32;
        while let Some(chunk) = body.data().await {
            let c = chunk.unwrap();
            body.flow_control().release_capacity(c.len()).unwrap();
            if c.is_empty() { continue }
            n += 1;
            let mut out = b"echo:".to_vec();
            out.extend_from_slice(&c);
            send.send_data(Bytes::from(out), false).unwrap();
        }
        let mut t = HeaderMap::new();
        t.insert("x-chunks", HeaderValue::from_str(&n.to_string()).unwrap());
        send.send_trailers(t).unwrap();
        return;
    }
    let mut all = Vec::new();
    while let Some(chunk) = body.data().await {
        let c = chunk.unwrap();
        body.flow_control().release_capacity(c.len()).unwrap();
        all.extend_from_slice(&c);
    }
    if path == "/echo" {
        let resp = Response::builder().status(200).body(()).unwrap();
        let mut send = respond.send_response(resp, false).unwrap();
        send.send_data(Bytes::from(all.to_ascii_uppercase()), false).unwrap();
        let mut t = HeaderMap::new();
        t.insert("x-len", HeaderValue::from_str(&all.len().to_string()).unwrap());
        send.send_trailers(t).unwrap();
    } else if path == "/sum" {
        let s: u64 = all.iter().map(|b| *b as u64).sum();
        let resp = Response::builder().status(200).body(()).unwrap();
        let mut send = respond.send_response(resp, false).unwrap();
        send.send_data(Bytes::from(s.to_string()), true).unwrap();
    } else if path == "/big" {
        let resp = Response::builder().status(200).body(()).unwrap();
        let mut send = respond.send_response(resp, false).unwrap();
        let data: Vec<u8> = (0..1048576usize).map(|i| (i % 251) as u8).collect();
        let mut off = 0;
        while off < data.len() {
            let want = std::cmp::min(65536, data.len() - off);
            send.reserve_capacity(want);
            let cap = std::future::poll_fn(|cx| send.poll_capacity(cx)).await.unwrap().unwrap();
            let n = std::cmp::min(cap, want);
            send.send_data(Bytes::copy_from_slice(&data[off..off + n]), off + n == data.len()).unwrap();
            off += n;
        }
    } else if let Some(n) = path.strip_prefix("/status/") {
        let resp = Response::builder().status(StatusCode::from_u16(n.parse().unwrap()).unwrap()).body(()).unwrap();
        respond.send_response(resp, true).unwrap();
    } else {
        respond.send_response(Response::builder().status(404).body(()).unwrap(), true).unwrap();
    }
}

#[tokio::main]
async fn main() {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    println!("listening {}", l.local_addr().unwrap().port());
    loop {
        let (tcp, _) = l.accept().await.unwrap();
        tokio::spawn(async move {
            let mut conn = match server::handshake(tcp).await { Ok(c) => c, Err(_) => return };
            while let Some(r) = conn.accept().await {
                if let Ok((req, respond)) = r { tokio::spawn(handle(req, respond)); } else { break }
            }
        });
    }
}
