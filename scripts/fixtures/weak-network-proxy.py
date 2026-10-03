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
# Byte budgets, bounded propagation delays, and destination write limits are
# explicit. Jitter uses a seeded PRNG per connection; the sequence replays for
# the same receive boundaries. Receive boundaries themselves are OS-dependent,
# so their propagation waits must overlap instead of limiting stream throughput.
#
# Control protocol, one JSON request line per connection, one JSON response
# line back, then close (the same shape as the herdr API socket):
#
#   {"command": "profile", "profile": {...}}  put a profile in force, live links included
#   {"command": "reset"}                      restore pass-through forwarding
#   {"command": "cut"}                        RST every live proxied connection
#   {"command": "stats"}                      counters since the last reset

import argparse
from collections import deque
from dataclasses import dataclass
import json
import random
import select
import socket
import struct
import threading
import time

RECEIVE_BYTES = 65536
PENDING_BYTES = 4 * RECEIVE_BYTES
POLL_SECONDS = 0.1


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
        # Delivery delay from each chunk's arrival, independent of later
        # arrivals. Propagation overlaps across a stream; sleeping before the
        # next receive would add an unintended recv-dependent rate limit.
        self.latency_millis = float(values.get("latencyMillis", 0))
        self.jitter_millis = float(values.get("jitterMillis", 0))
        self.jitter_seed = int(values.get("jitterSeed", 0))
        # Token bucket, refilled continuously; 0 disables the cap.
        self.bandwidth_bytes_per_second = int(values.get("bandwidthBytesPerSecond", 0))
        # Largest single write onto the destination socket. Small values force
        # the peer through many partial reads and EAGAIN cycles, which is the
        # shape of link that has surfaced readiness bugs before.
        self.segment_bytes = int(values.get("segmentBytes", 0))

    def describe(self) -> dict:
        return {
            "latencyMillis": self.latency_millis,
            "jitterMillis": self.jitter_millis,
            "jitterSeed": self.jitter_seed,
            "bandwidthBytesPerSecond": self.bandwidth_bytes_per_second,
            "segmentBytes": self.segment_bytes,
        }


class TokenBucket:
    """Continuously refilled byte budget; the whole cap when disabled."""

    def __init__(self, bytes_per_second: int) -> None:
        self.bytes_per_second = bytes_per_second
        self.available = float(bytes_per_second)
        self.updated_at = time.monotonic()

    def consume(self, count: int, stopped: threading.Event | None = None) -> bool:
        if self.bytes_per_second <= 0:
            return True
        # The ceiling must admit the request itself. Clamping at one second's
        # worth alone would make `available >= count` unreachable whenever a
        # segment is larger than the per-second budget, and the loop would then
        # sleep forever — wedging a pump thread, which no test deadline can
        # interrupt. Today's profiles never ask for it; a future one might.
        ceiling = max(float(self.bytes_per_second), float(count))
        while True:
            if stopped is not None and stopped.is_set():
                return False
            now = time.monotonic()
            self.available = min(
                ceiling,
                self.available + (now - self.updated_at) * self.bytes_per_second,
            )
            self.updated_at = now
            if self.available >= count:
                self.available -= count
                return True
            wait = (count - self.available) / self.bytes_per_second
            if stopped is None:
                time.sleep(wait)
            elif stopped.wait(wait):
                return False


@dataclass
class PendingChunk:
    ready_at: float
    profile: Profile
    data: bytes
    offset: int = 0


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
        self.stopped = threading.Event()
        # These two fixture-owned endpoints are shared only by this pair of
        # pumps. Nonblocking mode keeps every write cancellable on Darwin too,
        # where MSG_DONTWAIT alone does not prevent send-buffer waits.
        self.client.setblocking(False)
        self.upstream.setblocking(False)

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

    def cut(self) -> bool:
        """Severs both halves abruptly, so the peer sees RST rather than EOF.

        Returns whether this call was the one that severed the connection, so a
        second `cut` command over the same live set cannot count it twice.
        """
        with self.lock:
            if self.is_cut:
                return False
            self.is_cut = True
            self.stopped.set()
            # Keep reset preparation atomic with serve's normal cleanup: once
            # stopped is visible, both pumps may immediately return and join.
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
        return True

    def close(self) -> None:
        with self.lock:
            self.stopped.set()
            for endpoint in (self.client, self.upstream):
                # A close in one thread need not wake another thread's blocking
                # socket operation. Fatal errors must end both pumps before
                # serve can join them and remove this connection from the live set.
                try:
                    endpoint.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
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
        pending: deque[PendingChunk] = deque()
        pending_bytes = 0
        ended = False
        started = time.monotonic()
        cpu_started = time.thread_time()
        metrics = {
            "connection": self.index,
            "direction": direction,
            "receivedChunks": 0,
            "receivedBytes": 0,
            "smallestChunk": 0,
            "largestChunk": 0,
            "peakPendingBytes": 0,
            "scheduledLatencySeconds": 0.0,
            "latencyWaitSeconds": 0.0,
            "tokenWaitSeconds": 0.0,
            "sendWaitSeconds": 0.0,
            "deliveredBytes": 0,
            "exitReason": "stopped",
            "socketErrorCode": None,
        }

        try:
            while not self.stopped.is_set():
                if ended and not pending:
                    try:
                        destination.shutdown(socket.SHUT_WR)
                    except OSError as error:
                        metrics["exitReason"] = "shutdownError"
                        metrics["socketErrorCode"] = error.errno
                        self.close()
                        return
                    metrics["exitReason"] = "eof"
                    return

                now = time.monotonic()
                wait = min(POLL_SECONDS, max(0, pending[0].ready_at - now)) if pending else POLL_SECONDS
                readers = [source] if not ended and pending_bytes < PENDING_BYTES else []
                waiting_for_latency = bool(pending) and pending[0].ready_at > now
                waited_at = time.monotonic()
                try:
                    ready, _, _ = select.select(readers, [], [], wait)
                except (OSError, ValueError) as error:
                    metrics["exitReason"] = "selectError"
                    metrics["socketErrorCode"] = getattr(error, "errno", None)
                    self.close()
                    return
                if waiting_for_latency:
                    metrics["latencyWaitSeconds"] += time.monotonic() - waited_at

                if ready:
                    try:
                        chunk = source.recv(min(RECEIVE_BYTES, PENDING_BYTES - pending_bytes))
                    except BlockingIOError:
                        # Readiness can change before recv; try the selector
                        # again without treating a transient EAGAIN as EOF.
                        continue
                    except OSError as error:
                        metrics["exitReason"] = "receiveError"
                        metrics["socketErrorCode"] = error.errno
                        self.close()
                        return
                    if not chunk:
                        ended = True
                    else:
                        received_at = time.monotonic()
                        profile = self.proxy.current_profile()
                        if jitter is None:
                            jitter = random.Random(profile.jitter_seed + self.index)
                        delay = profile.latency_millis
                        if profile.jitter_millis > 0:
                            delay += jitter.uniform(0, profile.jitter_millis)
                        pending.append(PendingChunk(received_at + delay / 1000, profile, chunk))
                        pending_bytes += len(chunk)
                        metrics["receivedChunks"] += 1
                        metrics["receivedBytes"] += len(chunk)
                        metrics["smallestChunk"] = min(metrics["smallestChunk"] or len(chunk), len(chunk))
                        metrics["largestChunk"] = max(metrics["largestChunk"], len(chunk))
                        metrics["peakPendingBytes"] = max(metrics["peakPendingBytes"], pending_bytes)
                        metrics["scheduledLatencySeconds"] += delay / 1000

                if not pending or pending[0].ready_at > time.monotonic():
                    continue
                delivery = pending[0]
                profile, chunk, offset = delivery.profile, delivery.data, delivery.offset
                if bucket.bytes_per_second != profile.bandwidth_bytes_per_second:
                    bucket = TokenBucket(profile.bandwidth_bytes_per_second)
                span = profile.segment_bytes if profile.segment_bytes > 0 else len(chunk)
                segment = chunk[offset : offset + span]
                token_started = time.monotonic()
                consumed = bucket.consume(len(segment), self.stopped)
                metrics["tokenWaitSeconds"] += time.monotonic() - token_started
                if not consumed:
                    return
                send_started = time.monotonic()
                try:
                    sent = 0
                    while sent < len(segment):
                        if self.stopped.is_set():
                            return
                        # Nonblocking sends let cut interrupt a peer that
                        # stopped reading without issuing a graceful shutdown
                        # before the reset. Reserve tokens once per segment,
                        # then account only for bytes each short write sent.
                        try:
                            count = destination.send(segment[sent:])
                        except BlockingIOError:
                            select.select([], [destination], [], POLL_SECONDS)
                            continue
                        if count == 0:
                            metrics["exitReason"] = "sendZero"
                            self.close()
                            return
                        sent += count
                        metrics["deliveredBytes"] += count
                        self.proxy.count(direction, count)
                        pending_bytes -= count
                        delivery.offset += count
                except (OSError, ValueError) as error:
                    metrics["exitReason"] = "sendError"
                    metrics["socketErrorCode"] = getattr(error, "errno", None)
                    self.close()
                    return
                finally:
                    metrics["sendWaitSeconds"] += time.monotonic() - send_started
                if delivery.offset == len(chunk):
                    pending.popleft()
        finally:
            metrics["wallSeconds"] = time.monotonic() - started
            metrics["cpuSeconds"] = time.thread_time() - cpu_started
            metrics["cut"] = self.is_cut
            print("[weak-proxy] " + json.dumps(metrics, separators=(",", ":")), flush=True)


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
            severed = sum(1 for connection in live if connection.cut())
            with self.lock:
                self.cuts += severed
            return {"ok": True, "cutConnections": severed}
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
