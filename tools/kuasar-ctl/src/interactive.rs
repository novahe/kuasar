/*
Copyright 2022 The Kuasar Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

use std::os::unix::io::AsRawFd;

use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use vmm_sys_util::terminal::Terminal;

use crate::error::Result;

const EPOLL_EVENTS_LEN: usize = 16;

type StdResult<T> = std::result::Result<T, Error>;

#[derive(Debug)]
pub enum Error {
    EpollWait(&'static str),
    EpollCreate(&'static str),
    EpollAdd(&'static str),
    SocketWrite(&'static str),
    StdioErr(&'static str),
    InvalidState,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::EpollWait(msg) => write!(f, "epoll wait failed: {}", msg),
            Error::EpollCreate(msg) => write!(f, "epoll create failed: {}", msg),
            Error::EpollAdd(msg) => write!(f, "epoll add failed: {}", msg),
            Error::SocketWrite(msg) => write!(f, "socket write failed: {}", msg),
            Error::StdioErr(msg) => write!(f, "stdio error: {}", msg),
            Error::InvalidState => write!(f, "invalid state"),
        }
    }
}

impl std::error::Error for Error {}

#[derive(Debug, PartialEq)]
enum EpollDispatch {
    Stdin,
    ServerSock,
}

struct EpollContext {
    epoll_raw_fd: i32,
    stdin_index: u64,
    dispatch_table: Vec<EpollDispatch>,
    stdin_handle: io::Stdin,
    debug_console_sock: Option<UnixStream>,
}

impl EpollContext {
    fn new() -> StdResult<Self> {
        let epoll_raw_fd = epoll::create(true).map_err(|_| Error::EpollCreate("failed to create epoll instance"))?;
        let dispatch_table = Vec::new();
        let stdin_index = 0;

        Ok(EpollContext {
            epoll_raw_fd,
            stdin_index,
            dispatch_table,
            stdin_handle: io::stdin(),
            debug_console_sock: None,
        })
    }

    fn init_debug_console_sock(&mut self, sock: UnixStream) -> StdResult<()> {
        let dispatch_index = self.dispatch_table.len() as u64;
        epoll::ctl(
            self.epoll_raw_fd,
            epoll::ControlOptions::EPOLL_CTL_ADD,
            sock.as_raw_fd(),
            epoll::Event::new(epoll::Events::EPOLLIN, dispatch_index),
        )
        .map_err(|_| Error::EpollAdd("failed to add socket to epoll"))?;

        self.dispatch_table.push(EpollDispatch::ServerSock);
        self.debug_console_sock = Some(sock);

        Ok(())
    }

    fn enable_stdin_event(&mut self) -> StdResult<()> {
        let stdin_index = self.dispatch_table.len() as u64;
        epoll::ctl(
            self.epoll_raw_fd,
            epoll::ControlOptions::EPOLL_CTL_ADD,
            libc::STDIN_FILENO,
            epoll::Event::new(epoll::Events::EPOLLIN, stdin_index),
        )
        .map_err(|_| Error::EpollAdd("failed to add stdin to epoll"))?;

        self.stdin_index = stdin_index;
        self.dispatch_table.push(EpollDispatch::Stdin);

        Ok(())
    }

    fn do_exit(&self) {
        self.stdin_handle
            .lock()
            .set_canon_mode()
            .expect("Failed to restore stdin to canonical mode");
    }

    fn do_process_handler(&mut self) -> StdResult<()> {
        let mut events =
            [epoll::Event::new(epoll::Events::empty(), 0); EPOLL_EVENTS_LEN];

        let epoll_raw_fd = self.epoll_raw_fd;
        let debug_console_sock = self.debug_console_sock.as_mut()
            .ok_or(Error::InvalidState)?;

        loop {
            let num_events = epoll::wait(epoll_raw_fd, -1, &mut events[..])
                .map_err(|_| Error::EpollWait("epoll wait failed"))?;

            for event in events.iter().take(num_events) {
                let dispatch_index = event.data as usize;
                match self.dispatch_table[dispatch_index] {
                    EpollDispatch::Stdin => {
                        let mut out = [0u8; 8192];
                        let stdin_lock = self.stdin_handle.lock();
                        match stdin_lock.read_raw(&mut out[..]) {
                            Ok(0) => {
                                return Ok(());
                            }
                            Err(e) => {
                                eprintln!("errno {:?} while reading stdin", e);
                                return Ok(());
                            }
                            Ok(count) => {
                                debug_console_sock
                                    .write_all(&out[..count])
                                    .map_err(|_| Error::SocketWrite("failed to write to socket"))?;
                            }
                        }
                    }
                    EpollDispatch::ServerSock => {
                        let mut out = [0u8; 8192];
                        match debug_console_sock.read(&mut out[..]) {
                            Ok(0) => {
                                return Ok(());
                            }
                            Err(e) => {
                                eprintln!("errno {:?} while reading server", e);
                                return Ok(());
                            }
                            Ok(count) => {
                                io::stdout()
                                    .write_all(&out[..count])
                                    .map_err(|_| Error::StdioErr("failed to write to stdout"))?;
                                io::stdout().flush().map_err(|_| Error::StdioErr("failed to flush stdout"))?;
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Execute interactive session (matches kata-containers exec behavior)
pub fn execute_interactive(sock: UnixStream) -> Result<()> {
    let mut epoll_context = EpollContext::new()?;
    epoll_context.enable_stdin_event()?;
    epoll_context.init_debug_console_sock(sock)?;

    let stdin_handle = io::stdin();
    stdin_handle
        .lock()
        .set_raw_mode()
        .expect("set raw mode");

    epoll_context.do_process_handler()?;
    epoll_context.do_exit();

    Ok(())
}
