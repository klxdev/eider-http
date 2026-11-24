use axum::{routing::get, extract::Path, Router};

#[tokio::main]
async fn main() {
    let port = std::env::args().nth(1).unwrap_or("8081".into());
    let app = Router::new()
        .route("/", get(|| async { "hello" }))
        .route("/users/{id}", get(|Path(id): Path<String>| async move { id }));
    let l = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}")).await.unwrap();
    axum::serve(l, app).await.unwrap();
}
