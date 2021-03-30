use std::thread;
use std::net::{TcpListener, TcpStream, Shutdown};
use std::io::{Read, Write};
use std::sync::mpsc::{Sender, Receiver};
use std::sync::mpsc;

const WSCON: &'static str = "ws://127.0.0.1:8080";

extern crate redis;

fn connect() -> redis::Connection {
    let home = dirs::home_dir().expect("test").into_os_string().into_string().unwrap();
    let redis_path = format!("redis+unix://{}{}",home,"/.tmp/gdax_runner/redis.sock");
    redis::Client::open(redis_path)
        .expect("Invalid connection URL")
        .get_connection()
        .expect("failed to connect to Redis")
}

fn handle_client(mut stream: TcpStream) {
    let mut data = [0 as u8; 50]; // using 50 byte buffer

    let mut conn_set = connect();
    redis::cmd("PSUBSCRIBE").arg("*").execute(&mut conn_set);

    // let (tx, rx): (Sender<i32>, Receiver<i32>) = mpsc::channel();
    // thread::spawn(move|| {
    //     // connection succeeded
    //     redis_connect()
    // });
    //redis::cmd("PSUBSCRIBE").arg("*").execute(&mut _redis);

    while match stream.read(&mut data) {
        Ok(size) => {
            // echo everything!
            stream.write(&data[0..size]).unwrap();
            true
        },
        Err(_) => {
            println!("An error occurred, terminating connection with {}", stream.peer_addr().unwrap());
            stream.shutdown(Shutdown::Both).unwrap();
            false
        }
    } {}
}

fn main() {
    let listener = TcpListener::bind("0.0.0.0:10080").unwrap();
    // accept connections and process them, spawning a new thread for each one
    println!("Server listening on port 10080");
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                println!("New connection: {}", stream.peer_addr().unwrap());
                thread::spawn(move|| {
                    // connection succeeded
                    handle_client(stream)
                });
            }
            Err(e) => {
                println!("Error: {}", e);
                /* connection failed */
            }
        }
    }
    // close the socket server
    drop(listener);
}