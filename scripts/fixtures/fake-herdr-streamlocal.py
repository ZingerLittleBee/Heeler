#!/usr/bin/env python3

import argparse
import json
import os
import signal
import socket
import threading
import time


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--stale-socket", required=True)
    parser.add_argument("--count-file", required=True)
    return parser.parse_args()


class Server:
    def __init__(self, socket_path: str, stale_socket_path: str, count_file: str) -> None:
        self.socket_path = socket_path
        self.stale_socket_path = stale_socket_path
        self.count_file = count_file
        self.count = 0
        self.count_lock = threading.Lock()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    def start(self) -> None:
        self._unlink_paths()
        stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale.bind(self.stale_socket_path)
        stale.close()
        os.chmod(self.stale_socket_path, 0o777)

        self.listener.bind(self.socket_path)
        os.chmod(self.socket_path, 0o777)
        self.listener.listen()
        self._write_count()

        while True:
            connection, _ = self.listener.accept()
            threading.Thread(
                target=self._serve,
                args=(connection,),
                daemon=True,
            ).start()

    def close(self) -> None:
        self.listener.close()
        self._unlink_paths()

    def _serve(self, connection: socket.socket) -> None:
        with connection:
            self._increment_count()
            request = bytearray()
            while not request.endswith(b"\n"):
                chunk = connection.recv(1024)
                if not chunk:
                    return
                request.extend(chunk)

            envelope = json.loads(request)
            method = envelope.get("method")
            if method == "eof":
                return
            if method == "hang":
                time.sleep(30)
                return
            if method == "oversized":
                payload = b"x" * (1_048_576 + 1)
                chunk_size = 16 * 1024
            else:
                payload = json.dumps(
                    {
                        "id": envelope.get("id"),
                        "result": {"protocol": 17, "version": "fake"},
                    },
                    separators=(",", ":"),
                ).encode() + b"\n"
                chunk_size = 7

            for offset in range(0, len(payload), chunk_size):
                try:
                    connection.sendall(payload[offset : offset + chunk_size])
                except BrokenPipeError:
                    return

    def _increment_count(self) -> None:
        with self.count_lock:
            self.count += 1
            self._write_count()

    def _write_count(self) -> None:
        temporary = f"{self.count_file}.tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            handle.write(f"{self.count}\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, self.count_file)

    def _unlink_paths(self) -> None:
        for path in (self.socket_path, self.stale_socket_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def main() -> None:
    arguments = parse_arguments()
    server = Server(arguments.socket, arguments.stale_socket, arguments.count_file)

    def stop(_signal: int, _frame: object) -> None:
        server.close()
        raise SystemExit(0)

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    server.start()


if __name__ == "__main__":
    main()
