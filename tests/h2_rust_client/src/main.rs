// An HTTP/2 client (the `h2` crate) against tests/h2_interop_server.ei, prior-knowledge h2c:
//   h2_rust_client <port>
// Checks a unary call, a streamed upload that is answered chunk by chunk (bidirectional), trailers, a 4 MiB upload
// through the flow-control windows, a 1 MiB download, and 50 calls at once on one connection. Prints one line
// per check, `ok` or `FAIL`, and exits 1 on a failure.
use bytes::Bytes;
use h2::client;
use http::{Method, Request};
use std::process::exit;

type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

async fn body_of(mut r: h2::RecvStream) -> Res<(Vec<u8>, Option<http::HeaderMap>)> {
    let mut out = Vec::new();
    while let Some(chunk) = r.data().await {
        let c = chunk?;
        let n = c.len();
        out.extend_from_slice(&c);
        r.flow_control().release_capacity(n)?;
    }
    let t = r.trailers().await?;
    Ok((out, t))
}

async fn send_all(mut s: h2::SendStream<Bytes>, data: &[u8]) -> Res<()> {
    let mut off = 0;
    while off < data.len() {
        let want = std::cmp::min(data.len() - off, 65536);
        s.reserve_capacity(want);
        let cap = std::future::poll_fn(|cx| s.poll_capacity(cx)).await.ok_or("closed")??;
        let n = std::cmp::min(cap, want);
        let last = off + n == data.len();
        s.send_data(Bytes::copy_from_slice(&data[off..off + n]), last)?;
        off += n;
    }
    Ok(())
}

fn check(name: &str, ok: bool, bad: &mut u32) {
    if ok { println!("ok   {}", name) } else { println!("FAIL {}", name); *bad += 1 }
}

#[tokio::main]
async fn main() {
    let port = std::env::args().nth(1).expect("port");
    let mut bad = 0u32;
    let tcp = tokio::net::TcpStream::connect(format!("127.0.0.1:{}", port)).await.unwrap();
    let (client, conn) = client::handshake(tcp).await.unwrap();
    tokio::spawn(async move { let _ = conn.await; });
    let uri = |p: &str| format!("http://127.0.0.1:{}{}", port, p);

    // unary
    {
        let req = Request::builder().method(Method::POST).uri(uri("/echo")).body(()).unwrap();
        let (resp, send) = client.clone().ready().await.unwrap().send_request(req, false).unwrap();
        send_all(send, b"hello from rust").await.unwrap();
        let resp = resp.await.unwrap();
        let status = resp.status().as_u16();
        let (b, _) = body_of(resp.into_body()).await.unwrap();
        check("unary POST /echo", status == 200 && b == b"HELLO FROM RUST", &mut bad);
    }
    // bidirectional: three chunks, each answered before the next is sent, then trailers
    {
        let req = Request::builder().method(Method::POST).uri(uri("/bidi")).body(()).unwrap();
        let (resp, mut send) = client.clone().ready().await.unwrap().send_request(req, false).unwrap();
        let resp = resp.await.unwrap();
        let mut body = resp.into_body();
        let mut got = Vec::new();
        for m in ["one", "two", "three"] {
            send.reserve_capacity(m.len());
            let _ = std::future::poll_fn(|cx| send.poll_capacity(cx)).await;
            send.send_data(Bytes::from(m), false).unwrap();
            let c = body.data().await.unwrap().unwrap();
            body.flow_control().release_capacity(c.len()).unwrap();
            got.push(String::from_utf8(c.to_vec()).unwrap());
        }
        send.send_data(Bytes::new(), true).unwrap();
        let tr = loop {
            match body.data().await {
                Some(c) => { let c = c.unwrap(); body.flow_control().release_capacity(c.len()).unwrap(); }
                None => break body.trailers().await.unwrap(),
            }
        };
        let chunks = tr.as_ref().and_then(|t| t.get("x-chunks")).map(|v| v.to_str().unwrap().to_string());
        check("bidirectional /bidi", got == ["echo:one", "echo:two", "echo:three"] && chunks.as_deref() == Some("3"), &mut bad);
    }
    // trailers
    {
        let req = Request::builder().method(Method::GET).uri(uri("/trailers")).body(()).unwrap();
        let (resp, _) = client.clone().ready().await.unwrap().send_request(req, true).unwrap();
        let resp = resp.await.unwrap();
        let (b, t) = body_of(resp.into_body()).await.unwrap();
        let t = t.unwrap();
        check("trailers /trailers", b == b"payload" && t.get("grpc-status").unwrap() == "0" && t.get("grpc-message").unwrap() == "ok", &mut bad);
    }
    // 4 MiB upload (the server buffers up to 1 MiB: 413), 1 MiB download
    {
        let req = Request::builder().method(Method::POST).uri(uri("/echo")).body(()).unwrap();
        let (resp, send) = client.clone().ready().await.unwrap().send_request(req, false).unwrap();
        let data = vec![b'a'; 4 << 20];
        let up = tokio::spawn(send_all(send, &data.clone().leak()[..]));
        let resp = resp.await.unwrap();
        let _ = up.await;
        check("4 MiB upload is refused with 413", resp.status().as_u16() == 413, &mut bad);
        let req = Request::builder().method(Method::GET).uri(uri("/big")).body(()).unwrap();
        let (resp, _) = client.clone().ready().await.unwrap().send_request(req, true).unwrap();
        let resp = resp.await.unwrap();
        let (b, _) = body_of(resp.into_body()).await.unwrap();
        let ok = b.len() == 1 << 20 && b.iter().enumerate().all(|(i, x)| *x == (i % 251) as u8);
        check("1 MiB download /big", ok, &mut bad);
    }
    // 50 at once
    {
        let mut tasks = Vec::new();
        for i in 0..50 {
            let c = client.clone();
            let u = uri("/echo");
            tasks.push(tokio::spawn(async move {
                let req = Request::builder().method(Method::POST).uri(u).body(()).unwrap();
                let (resp, send) = c.ready().await.unwrap().send_request(req, false).unwrap();
                let msg = format!("call {}", i);
                send_all(send, msg.as_bytes()).await.unwrap();
                let resp = resp.await.unwrap();
                let (b, _) = body_of(resp.into_body()).await.unwrap();
                b == msg.to_uppercase().as_bytes()
            }));
        }
        let mut all = true;
        for t in tasks { all &= t.await.unwrap(); }
        check("50 concurrent calls", all, &mut bad);
    }
    if bad > 0 { exit(1) }
}
