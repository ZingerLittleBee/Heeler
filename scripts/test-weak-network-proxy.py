#!/usr/bin/env python3
"""Real TCP regressions for byte-stream impairment and lifecycle behavior."""

import contextlib
import importlib.util
from pathlib import Path
import random
import socket
import threading
import time
import unittest

SPEC = importlib.util.spec_from_file_location(
    "weak_network_proxy", Path(__file__).parent / "fixtures" / "weak-network-proxy.py")
proxy_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy_module)

DEGRADED = {
    "latencyMillis": 40,
    "jitterMillis": 15,
    "jitterSeed": 7,
    "bandwidthBytesPerSecond": 256 * 1024,
    "segmentBytes": 512,
}


def tcp_pair():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        writer = socket.create_connection(listener.getsockname())
        reader, _ = listener.accept()
    for endpoint in (writer, reader):
        endpoint.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return writer, reader


class ReceiveShape:
    """Limit real TCP reads without replacing their bytes or readiness."""

    def __init__(self, endpoint, cap):
        self.endpoint = endpoint
        self.cap = cap
        self.received = threading.Event()
        self.reads = []

    def recv(self, count):
        chunk = self.endpoint.recv(min(count, self.cap))
        if chunk:
            self.reads.append(len(chunk))
            self.received.set()
        return chunk

    def fileno(self):
        return self.endpoint.fileno()


class RecordWrites:
    def __init__(self, endpoint):
        self.endpoint = endpoint
        self.writes = []
        self.first_write = None

    def sendall(self, chunk):
        if self.first_write is None:
            self.first_write = time.monotonic()
        self.writes.append(len(chunk))
        self.endpoint.sendall(chunk)

    def shutdown(self, direction):
        self.endpoint.shutdown(direction)


class Forwarding:
    def __init__(self, profile, receive_cap=65536):
        self.sender, self.ingress = tcp_pair()
        self.egress, self.receiver = tcp_pair()
        self.source = ReceiveShape(self.ingress, receive_cap)
        self.destination = RecordWrites(self.egress)
        self.proxy = proxy_module.Proxy(0, 0, "127.0.0.1", 0)
        self.profile(profile)
        self.connection = proxy_module.Connection(1, self.ingress, self.egress, self.proxy)
        self.thread = threading.Thread(
            target=self.connection._pump,
            args=(self.source, self.destination, "toClient"), daemon=True)
        self.thread.start()

    def profile(self, values):
        return self.proxy._handle({"command": "profile", "profile": values})

    def close(self):
        self.connection.close()
        for endpoint in (self.sender, self.receiver):
            with contextlib.suppress(OSError):
                endpoint.shutdown(socket.SHUT_RDWR)
            endpoint.close()
        self.thread.join(timeout=1)

    def transfer(self, payload):
        output = bytearray()
        errors = []

        def receive():
            try:
                while chunk := self.receiver.recv(65536):
                    output.extend(chunk)
            except OSError as error:
                errors.append(error)

        reader = threading.Thread(target=receive, daemon=True)
        reader.start()
        started = time.monotonic()
        self.sender.sendall(payload)
        self.sender.shutdown(socket.SHUT_WR)
        self.thread.join(timeout=10)
        reader.join(timeout=1)
        elapsed = time.monotonic() - started
        if self.thread.is_alive() or reader.is_alive():
            raise AssertionError("forwarding did not finish")
        if errors:
            raise errors[0]
        return bytes(output), elapsed, self.destination.first_write - started


class WeakNetworkProxyTests(unittest.TestCase):
    def forwarding(self, profile=DEGRADED, receive_cap=65536):
        forwarding = Forwarding(profile, receive_cap)
        self.addCleanup(forwarding.close)
        return forwarding

    def test_receive_boundaries_do_not_add_a_second_bandwidth_limit(self):
        payload = bytes(range(256)) * 512
        outcomes = []
        for cap in (65536, 2048):
            forwarding = self.forwarding(receive_cap=cap)
            output, elapsed, first_delivery = forwarding.transfer(payload)
            self.assertEqual(output, payload)
            self.assertGreaterEqual(first_delivery, 0.04)
            self.assertLessEqual(max(forwarding.destination.writes), 512)
            self.assertEqual(
                forwarding.proxy._handle({"command": "stats"})["bytesToClient"], len(payload))
            self.assertEqual(forwarding.profile(DEGRADED)["profile"], DEGRADED)
            outcomes.append(elapsed)
        self.assertLess(outcomes[1], 1, f"recv-dependent delay: {outcomes}")

    def test_bandwidth_cap_still_limits_a_transfer_past_its_burst(self):
        forwarding = self.forwarding(receive_cap=2048)
        payload = bytes(range(256)) * 2048
        output, elapsed, _ = forwarding.transfer(payload)
        self.assertEqual(output, payload)
        self.assertGreaterEqual(elapsed, 1)
        self.assertLess(elapsed, 3)
        self.assertLessEqual(max(forwarding.destination.writes), 512)

    def test_seeded_jitter_is_added_to_the_propagation_floor(self):
        profile = {**DEGRADED, "jitterSeed": 51}
        forwarding = self.forwarding(profile)
        output, _, first_delivery = forwarding.transfer(b"jitter")
        expected = (40 + random.Random(52).uniform(0, 15)) / 1000
        self.assertEqual(output, b"jitter")
        self.assertGreaterEqual(first_delivery, expected)

    def test_pass_through_preserves_bytes_and_half_close(self):
        forwarding = self.forwarding({})
        payload = bytes(range(256)) * 1024
        output, _, _ = forwarding.transfer(payload)
        self.assertEqual(output, payload)
        self.assertFalse(forwarding.thread.is_alive())

    def test_live_profile_change_keeps_accepted_bytes_delayed_and_ordered(self):
        forwarding = self.forwarding({"latencyMillis": 200}, receive_cap=1)
        captured = threading.Event()
        release = threading.Event()
        self.addCleanup(release.set)
        current_profile = forwarding.proxy.current_profile
        snapshots = []

        def capture_first_profile():
            profile = current_profile()
            if not snapshots:
                # The real accessor has returned the old immutable profile.
                # Changing the proxy while this return is paused cannot change
                # the object the pump will enqueue for its first chunk.
                snapshots.append(profile)
                captured.set()
                release.wait(timeout=2)
            return profile

        forwarding.proxy.current_profile = capture_first_profile
        started = time.monotonic()
        forwarding.sender.sendall(b"A")
        self.assertTrue(captured.wait(timeout=1))
        self.assertEqual(snapshots[0].latency_millis, 200)
        forwarding.profile({})
        release.set()
        forwarding.sender.sendall(b"B")
        forwarding.sender.shutdown(socket.SHUT_WR)
        forwarding.receiver.settimeout(2)
        output = bytearray()
        while chunk := forwarding.receiver.recv(16):
            output.extend(chunk)
        self.assertEqual(output, b"AB")
        self.assertGreaterEqual(forwarding.destination.first_write - started, 0.2)

    def test_cut_interrupts_bandwidth_starvation_and_counts_once(self):
        forwarding = self.forwarding({"bandwidthBytesPerSecond": 1, "segmentBytes": 512})
        with forwarding.proxy.lock:
            forwarding.proxy.connections.append(forwarding.connection)
        forwarding.sender.sendall(b"x" * 512)
        self.assertTrue(forwarding.source.received.wait(timeout=1))
        time.sleep(0.05)
        self.assertTrue(forwarding.thread.is_alive())
        self.assertEqual(forwarding.destination.writes, [])
        started = time.monotonic()
        self.assertEqual(forwarding.proxy._handle({"command": "cut"})["cutConnections"], 1)
        self.assertEqual(forwarding.proxy._handle({"command": "cut"})["cutConnections"], 0)
        forwarding.thread.join(timeout=1)
        self.assertFalse(forwarding.thread.is_alive())
        self.assertLess(time.monotonic() - started, 1)
        self.assertEqual(forwarding.proxy._handle({"command": "stats"})["cutConnections"], 1)

    def test_cut_stops_a_pump_waiting_for_input(self):
        forwarding = self.forwarding({})
        self.assertTrue(forwarding.connection.cut())
        forwarding.thread.join(timeout=1)
        self.assertFalse(forwarding.thread.is_alive())

    def test_close_stops_a_pump_waiting_for_long_propagation(self):
        forwarding = self.forwarding({"latencyMillis": 30_000})
        forwarding.sender.sendall(b"pending")
        self.assertTrue(forwarding.source.received.wait(timeout=1))
        forwarding.connection.close()
        forwarding.thread.join(timeout=1)
        self.assertFalse(forwarding.thread.is_alive())
        self.assertEqual(forwarding.destination.writes, [])

    def test_pending_propagation_backpressures_the_sender(self):
        forwarding = self.forwarding({"latencyMillis": 30_000})
        for endpoint in (forwarding.sender, forwarding.ingress, forwarding.egress, forwarding.receiver):
            endpoint.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
            endpoint.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        forwarding.sender.settimeout(0.1)
        with self.assertRaises(TimeoutError):
            forwarding.sender.sendall(b"x" * (16 * 1024 * 1024))

    def test_reset_restores_profile_and_counters_without_reusing_connections(self):
        forwarding = self.forwarding()
        forwarding.proxy.accepted = 3
        output, _, _ = forwarding.transfer(b"profile reset")
        self.assertEqual(output, b"profile reset")
        self.assertEqual(forwarding.proxy._handle({"command": "reset"}), {"ok": True})
        stats = forwarding.proxy._handle({"command": "stats"})
        self.assertEqual(stats["acceptedConnections"], 3)
        self.assertEqual(stats["bytesToClient"], 0)
        self.assertEqual(forwarding.proxy.current_profile().describe()["latencyMillis"], 0)


if __name__ == "__main__":
    unittest.main()
