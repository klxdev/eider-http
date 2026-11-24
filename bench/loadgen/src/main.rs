// loadgen <port> <path> <conns> <threads> <seconds>: keep-alive HTTP/1.1 GETs, one outstanding
// request per connection; each thread owns conns/threads sockets, sends on all then reads all.
// A connection the server closes (max_requests, Connection: close) is reopened and counted.
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

fn open(port: u16) -> TcpStream {
    let s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    s.set_nodelay(true).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    s
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let port: u16 = a[1].parse().unwrap();
    let path = a[2].clone();
    let conns: usize = a[3].parse().unwrap();
    let threads: usize = a[4].parse().unwrap();
    let secs: u64 = a[5].parse().unwrap();
    let req = format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: */*\r\n\r\n").into_bytes();
    let stop = Arc::new(AtomicBool::new(false));
    let total = Arc::new(AtomicU64::new(0));
    let errs = Arc::new(AtomicU64::new(0));
    let reconns = Arc::new(AtomicU64::new(0));
    let mut hs = vec![];
    for t in 0..threads {
        let n = conns / threads + if t < conns % threads { 1 } else { 0 };
        let (stop, total, errs, reconns, req) = (stop.clone(), total.clone(), errs.clone(), reconns.clone(), req.clone());
        hs.push(std::thread::spawn(move || {
            let mut socks: Vec<TcpStream> = (0..n).map(|_| open(port)).collect();
            let mut buf = vec![0u8; 65536];
            let mut count = 0u64;
            while !stop.load(Ordering::Relaxed) {
                for s in socks.iter_mut() {
                    if s.write_all(&req).is_err() { *s = open(port); reconns.fetch_add(1, Ordering::Relaxed); let _ = s.write_all(&req); }
                }
                for s in socks.iter_mut() {
                    match s.read(&mut buf) {
                        Ok(k) if k > 0 && buf.starts_with(b"HTTP/1.1 200") => {
                            count += 1;
                            // the server said it is closing: reopen before the next round
                            if buf[..k].windows(17).any(|w| w.eq_ignore_ascii_case(b"connection: close")) {
                                *s = open(port); reconns.fetch_add(1, Ordering::Relaxed);
                            }
                        }
                        _ => { errs.fetch_add(1, Ordering::Relaxed); *s = open(port); reconns.fetch_add(1, Ordering::Relaxed); }
                    }
                }
            }
            total.fetch_add(count, Ordering::Relaxed);
        }));
    }
    let t0 = Instant::now();
    std::thread::sleep(Duration::from_secs(secs));
    stop.store(true, Ordering::Relaxed);
    for h in hs { h.join().unwrap(); }
    let el = t0.elapsed().as_secs_f64();
    let n = total.load(Ordering::Relaxed);
    println!("{:>8.0} req/s ({} reqs in {:.1}s, {} errors, {} reconnects)", n as f64 / el, n, el, errs.load(Ordering::Relaxed), reconns.load(Ordering::Relaxed));
}
