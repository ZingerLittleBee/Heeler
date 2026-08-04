#!/usr/bin/env python3
#
# Unprivileged TCP impairment proxy for the weak-network suites.
#
# The merge gate runs without sudo, so `pfctl`/`dummynet` and the Network Link
# Conditioner are both unavailable and machine-wide. This proxy degrades one
# TCP path instead: the suites point their Host at the proxy's listen port and
# it forwards to the fixture sshd, delaying, rate limiting, fragmenting, and
# abruptly severing the byte stream on the way.
#
# Every impairment is a function of byte counts and fixed durations, so a given
# profile produces the same treatment on every run. The one stochastic knob,
# jitter, is drawn from an explicitly seeded PRNG per connection, so it too
# replays exactly. Nothing here sleeps for an unspecified amount of time.
#
# Control protocol, one JSON request line per connection, one JSON response
# line back, then close (the same shape as the herdr API socket):
#
#   {"command": "profile", "profile": {...}}  put a profile in force, live links included
#   {"command": "reset"}                      restore pass-through forwarding
#   {"command": "cut"}                        RST every live proxied connection
#   {"command": "stats"}                      counters since the last reset

import argparse
import json
import random
import socket
import struct
import threading
import time

RECEIVE_BYTES = 65536


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--control-port", type=int, required=True)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, required=True)
    return parser.parse_args()


class Profile:
    """One deterministic impairment recipe, applied per direction."""

    def __init__(self, values: object = None) -> None:
        values = values if isinstance(values, dict) else {}
        # Delivery delay for each chunk read off the source socket. Applied
        # once per chunk rather than per fragment, so it models propagation
        # delay instead of silently becoming a second rate limit.
        self.latency_millis = float(values.get("latencyMillis", 0))
        self.jitter_millis = float(values.get("jitterMillis", 0))
        self.jitter_seed = int(values.get("jitterSeed", 0))
        # Token bucket, refilled continuously; 0 disables the cap.
        self.bandwidth_bytes_per_second = int(values.get("bandwidthBytesPerSecond", 0))
        # Largest single write onto the destination socket. Small values force
        # the peer through many partial reads and EAGAIN cycles, which is the
        # shape of link that has surfaced readiness bugs before.
        self.segment_bytes = int(values.get("segmentBytes", 0))
        # Abrupt loss: RST the connection once this many bytes have crossed in
        # that direction. 0 disables it.
        self.cut_after_bytes_to_server = int(values.get("cutAfterBytesToServer", 0))
        self.cut_after_bytes_to_client = int(values.get("cutAfterBytesToClient", 0))

    def describe(self) -> dict:
        return {
            "latencyMillis": self.latency_millis,
            "jitterMillis": self.jitter_millis,
            "jitterSeed": self.jitter_seed,
            "bandwidthBytesPerSecond": self.bandwidth_bytes_per_second,
            "segmentBytes": self.segment_bytes,
            "cutAfterBytesToServer": self.cut_after_bytes_to_server,
            "cutAfterBytesToClient": self.cut_after_bytes_to_client,
        }


class TokenBucket:
    """Continuously refilled byte budget; the whole cap when disabled."""

    def __init__(self, bytes_per_second: int) -> None:
        self.bytes_per_second = bytes_per_second
        self.available = float(bytes_per_second)
        self.updated_at = time.monotonic()

    def consume(self, count: int) -> None:
        if self.bytes_per_second <= 0:
            return
        # The ceiling must admit the request itself. Clamping at one second's
        # worth alone would make `available >= count` unreachable whenever a
        # segment is larger than the per-second budget, and the loop would then
        # sleep forever — wedging a pump thread, which no test deadline can
        # interrupt. Today's profiles never ask for it; a future one might.
        ceiling = max(float(self.bytes_per_second), float(count))
        while True:
            now = time.monotonic()
            self.available = min(
                ceiling,
                self.available + (now - self.updated_at) * self.bytes_per_second,
            )
            self.updated_at = now
            if self.available >= count:
                self.available -= count
                return
            time.sleep((count - self.available) / self.bytes_per_second)


class Connection:
    """One proxied TCP pair, impaired by whichever profile is in force."""

    def __init__(self, index: int, client: socket.socket, upstream: socket.socket,
                 proxy: "Proxy") -> None:
        self.index = index
        self.client = client
        self.upstream = upstream
        self.proxy = proxy
        self.lock = threading.Lock()
        self.is_cut = False

    def serve(self) -> None:
        threads = [
            threading.Thread(
                target=self._pump,
                args=(self.client, self.upstream, "toServer"),
                daemon=True,
            ),
            threading.Thread(
                target=self._pump,
                args=(self.upstream, self.client, "toClient"),
                daemon=True,
            ),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.close()
        self.proxy.forget(self)

    def cut(self) -> None:
        """Sever both halves abruptly, so the peer sees RST rather than EOF."""
        with self.lock:
            if self.is_cut:
                return
            self.is_cut = True
        linger = struct.pack("ii", 1, 0)
        for endpoint in (self.client, self.upstream):
            try:
                endpoint.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, linger)
            except OSError:
                pass
            try:
                endpoint.close()
            except OSError:
                pass

    def close(self) -> None:
        for endpoint in (self.client, self.upstream):
            try:
                endpoint.close()
            except OSError:
                pass

    def _pump(self, source: socket.socket, destination: socket.socket,
              direction: str) -> None:
        # The profile is re-read once per chunk rather than snapshotted at
        # accept, so a test can degrade a link that is already carrying an SSH
        # session. Re-reading at a chunk boundary keeps the change observable
        # at a well-defined point instead of part-way through a write.
        bucket = TokenBucket(0)
        jitter = None
        forwarded = 0

        while True:
            try:
                chunk = source.recv(RECEIVE_BYTES)
            except OSError:
                return
            if not chunk:
                try:
                    destination.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                return

            profile = self.proxy.current_profile()
            if bucket.bytes_per_second != profile.bandwidth_bytes_per_second:
                bucket = TokenBucket(profile.bandwidth_bytes_per_second)
            if jitter is None:
                jitter = random.Random(profile.jitter_seed + self.index)
            limit = (
                profile.cut_after_bytes_to_server
                if direction == "toServer"
                else profile.cut_after_bytes_to_client
            )

            delay = profile.latency_millis
            if profile.jitter_millis > 0:
                delay += jitter.uniform(0, profile.jitter_millis)
            if delay > 0:
                time.sleep(delay / 1000)

            span = profile.segment_bytes if profile.segment_bytes > 0 else len(chunk)
            for offset in range(0, len(chunk), span):
                segment = chunk[offset : offset + span]
                bucket.consume(len(segment))
                try:
                    destination.sendall(segment)
                except OSError:
                    return
                forwarded += len(segment)
                self.proxy.count(direction, len(segment))
                if limit > 0 and forwarded >= limit:
                    self.cut()
                    return


class Proxy:
    def __init__(self, listen_port: int, control_port: int, target_host: str,
                 target_port: int) -> None:
        self.listen_port = listen_port
        self.control_port = control_port
        self.target = (target_host, target_port)
        self.lock = threading.Lock()
        self.profile = Profile()
        self.connections: list[Connection] = []
        self.accepted = 0
        self.cuts = 0
        self.bytes_to_server = 0
        self.bytes_to_client = 0

    def start(self) -> None:
        threading.Thread(target=self._serve_control, daemon=True).start()
        self._serve_data()

    def current_profile(self) -> Profile:
        with self.lock:
            return self.profile

    def forget(self, connection: Connection) -> None:
        with self.lock:
            if connection in self.connections:
                self.connections.remove(connection)

    def count(self, direction: str, byte_count: int) -> None:
        with self.lock:
            if direction == "toServer":
                self.bytes_to_server += byte_count
            else:
                self.bytes_to_client += byte_count

    def _serve_data(self) -> None:
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", self.listen_port))
        listener.listen(64)
        while True:
            client, _ = listener.accept()
            client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            try:
                upstream = socket.create_connection(self.target, timeout=5)
            except OSError:
                client.close()
                continue
            upstream.settimeout(None)
            upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with self.lock:
                self.accepted += 1
                index = self.accepted
                connection = Connection(index, client, upstream, self)
                self.connections.append(connection)
            threading.Thread(target=connection.serve, daemon=True).start()

    def _serve_control(self) -> None:
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", self.control_port))
        listener.listen(16)
        while True:
            connection, _ = listener.accept()
            threading.Thread(
                target=self._serve_control_request,
                args=(connection,),
                daemon=True,
            ).start()

    def _serve_control_request(self, connection: socket.socket) -> None:
        with connection:
            request = bytearray()
            while not request.endswith(b"\n"):
                try:
                    chunk = connection.recv(4096)
                except OSError:
                    return
                if not chunk:
                    return
                request.extend(chunk)
            try:
                envelope = json.loads(request)
            except ValueError:
                response = {"error": "malformed request"}
            else:
                response = self._handle(envelope)
            payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
            try:
                connection.sendall(payload)
            except OSError:
                pass

    def _handle(self, envelope: object) -> dict:
        if not isinstance(envelope, dict):
            return {"error": "malformed request"}
        command = envelope.get("command")
        if command == "profile":
            profile = Profile(envelope.get("profile"))
            with self.lock:
                self.profile = profile
            return {"ok": True, "profile": profile.describe()}
        if command == "reset":
            with self.lock:
                self.profile = Profile()
                self.bytes_to_server = 0
                self.bytes_to_client = 0
                self.cuts = 0
            return {"ok": True}
        if command == "cut":
            with self.lock:
                live = list(self.connections)
                self.cuts += len(live)
            for connection in live:
                connection.cut()
            return {"ok": True, "cutConnections": len(live)}
        if command == "stats":
            with self.lock:
                return {
                    "ok": True,
                    "acceptedConnections": self.accepted,
                    "liveConnections": len(self.connections),
                    "cutConnections": self.cuts,
                    "bytesToServer": self.bytes_to_server,
                    "bytesToClient": self.bytes_to_client,
                }
        return {"error": "unknown command"}


def main() -> None:
    arguments = parse_arguments()
    Proxy(
        arguments.listen_port,
        arguments.control_port,
        arguments.target_host,
        arguments.target_port,
    ).start()


if __name__ == "__main__":
    main()
