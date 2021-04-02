use std::thread;
use std::net::{TcpListener, TcpStream};
use std::io::{Write};
use std::time::Duration;

extern crate redis;

fn handle_client(mut stream: TcpStream) {
    // let data = [0 as u8; 50]; // using 50 byte buffer

    let homex = dirs::home_dir().unwrap().into_os_string().into_string().unwrap();
    let redis_pathx = format!("redis+unix://{}{}",homex,"/.tmp/gdax_runner/redis.sock");
    let mut redis_rx = redis::Client::open(redis_pathx).unwrap();

    let home = dirs::home_dir().unwrap().into_os_string().into_string().unwrap();
    let redis_path = format!("redis+unix://{}{}",home,"/.tmp/gdax_runner/redis.sock");

    let client = redis::Client::open(redis_path).unwrap();
    let mut con = client.get_connection().unwrap();
    let mut pubsub = con.as_pubsub();
    pubsub.psubscribe("BTC-US*").unwrap();

    loop {
        let msg = match pubsub.get_message() {
            Ok(message_rx_success) => {
                message_rx_success
            },
            Err(_) => {
                thread::sleep(Duration::from_millis(1));
                continue;
            }
        };
        let payload : String = msg.get_payload().unwrap();
        let mut pkey = format!("{}:{}",msg.get_channel_name(), payload);

        // Create a clone for debug messages
        let mut pketClone = pkey.clone();

        // Drop duplicates
        

        let json_packet: String = match redis::cmd("GET").arg(pkey).query(&mut redis_rx) {
            Ok(json_test) => {
                json_test
            },
            Err(e) => {
                println!("Failed to read REDIS DATA: {}", pketClone);
                continue;
            }
        };

        match stream.write(format!("{}\n",json_packet).as_bytes()) {
            Ok(_) => {
                // ? Errr do nothing it worked?
            },
            Err(e) => {
                println!("Failed to send data: {}", e);
                break;
            }
        }
    }
}

fn main() {
    let listener = TcpListener::bind("0.0.0.0:10081").unwrap();
    // accept connections and process them, spawning a new thread for each one
    println!("Server listening on port 10081");
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