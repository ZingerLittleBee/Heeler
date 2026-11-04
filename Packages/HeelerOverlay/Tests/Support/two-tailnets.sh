#!/bin/sh
# Two independent Headscale tailnets in Docker for
# TailscaleTwoTailnetLiveTests.
#
#   Tests/Support/two-tailnets.sh up     # start, then print the test variables
#   Tests/Support/two-tailnets.sh env    # print them again
#   Tests/Support/two-tailnets.sh down   # remove the containers and state
#
# Tailnet A has heeler-hs-a-peer (100.64.0.1, banner SSH-2.0-TailnetA);
# tailnet B has heeler-hs-b-peer (100.64.0.1, SSH-2.0-TailnetB),
# heeler-hs-b-peer2 (100.64.0.2) and heeler-hs-b-peer3 (100.64.0.3,
# SSH-2.0-TailnetB3). Both use 100.64.0.0/10, so their addresses overlap.
#
# The servers speak plain HTTP on HOST_IP (default: en0's address, which the
# Simulator and the containers both reach), and each runs Headscale's
# embedded DERP. Tailscale clients only speak TLS to DERP, so the containers
# and the test (TEST_RUNNER_TS_DEBUG_USE_DERP_HTTP=1) must use the
# TS_DEBUG_USE_DERP_HTTP knob; without DERP no path forms.
set -eu

HEADSCALE_IMAGE=${HEADSCALE_IMAGE:-headscale/headscale:v0.29.4}
TAILSCALE_IMAGE=${TAILSCALE_IMAGE:-tailscale/tailscale:v1.102.5}
WORK=${WORK:-/tmp/heeler-two-tailnets}
HOST_IP=${HOST_IP:-$(ipconfig getifaddr en0 2>/dev/null || true)}
[ -n "$HOST_IP" ] || { echo "Set HOST_IP to an address the Simulator reaches." >&2; exit 1; }

port() { [ "$1" = a ] && echo 18081 || echo 18082; }
stun() { [ "$1" = a ] && echo 13478 || echo 13479; }

server() {
    tailnet=$1
    mkdir -p "$WORK/$tailnet/config"
    cat > "$WORK/$tailnet/config/config.yaml" <<EOF
server_url: http://$HOST_IP:$(port "$tailnet")
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  server:
    enabled: true
    region_id: 999
    region_code: heeler
    region_name: Heeler local
    stun_listen_addr: 0.0.0.0:$(stun "$tailnet")
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
    ipv4: $HOST_IP
  urls: []
  paths: []
  auto_update_enabled: false
disable_check_updates: true
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
dns:
  magic_dns: false
  base_domain: ts$tailnet.example
  override_local_dns: false
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
EOF
    docker rm -f "heeler-hs-$tailnet" >/dev/null 2>&1 || true
    docker run -d --name "heeler-hs-$tailnet" \
        -p "$(port "$tailnet"):8080" -p "$(stun "$tailnet"):$(stun "$tailnet")/udp" \
        -v "$WORK/$tailnet/config:/etc/headscale" -v "heeler-hs-$tailnet-data:/var/lib/headscale" \
        "$HEADSCALE_IMAGE" serve >/dev/null
    for _ in $(seq 1 30); do
        docker exec "heeler-hs-$tailnet" headscale users create "tn$tailnet" >/dev/null 2>&1 && break
        sleep 1
    done
    docker exec "heeler-hs-$tailnet" headscale preauthkeys create --user 1 --reusable --expiration 24h -o json \
        | python3 -c 'import json, sys; print(json.load(sys.stdin)["key"])' > "$WORK/key-$tailnet"
}

peer() {
    name=$1 tailnet=$2 banner=$3
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --hostname "$name" \
        -e TS_AUTHKEY="$(cat "$WORK/key-$tailnet")" \
        -e TS_EXTRA_ARGS="--login-server=http://$HOST_IP:$(port "$tailnet")" \
        -e TS_USERSPACE=true -e TS_STATE_DIR=/var/lib/tailscale -e TS_HOSTNAME="$name" \
        -e TS_DEBUG_USE_DERP_HTTP=1 "$TAILSCALE_IMAGE" >/dev/null
    for _ in $(seq 1 30); do
        address=$(docker exec "$name" tailscale ip -4 2>/dev/null || true)
        [ -n "$address" ] && break
        sleep 1
    done
    # Userspace networking forwards the tailnet's port 22 to localhost:22.
    docker exec "$name" sh -c "printf '#!/bin/sh\necho SSH-2.0-$banner\nsleep 2\n' > /banner.sh && chmod +x /banner.sh"
    docker exec -d "$name" nc -lk -p 22 -e /banner.sh
    echo "$name ${address:-?}" >&2
}

remove_containers() {
    docker rm -f heeler-hs-a heeler-hs-b heeler-hs-a-peer heeler-hs-b-peer \
        heeler-hs-b-peer2 heeler-hs-b-peer3 >/dev/null 2>&1 || true
    # Server state lives in volumes: a re-created bind-mounted directory can
    # be stale in Docker's view (seen with OrbStack).
    docker volume rm heeler-hs-a-data heeler-hs-b-data >/dev/null 2>&1 || true
}

print_env() {
    cat <<EOF
TEST_RUNNER_HEELER_TS2=1
TEST_RUNNER_TS_DEBUG_USE_DERP_HTTP=1
TEST_RUNNER_TS2_A_URL=http://$HOST_IP:$(port a)
TEST_RUNNER_TS2_A_KEY=$(cat "$WORK/key-a")
TEST_RUNNER_TS2_B_URL=http://$HOST_IP:$(port b)
TEST_RUNNER_TS2_B_KEY=$(cat "$WORK/key-b")
EOF
}

case ${1:-} in
up)
    # Fresh servers: a node left over from an earlier run would take the
    # addresses and names the test expects.
    remove_containers
    server a
    server b
    # Registration order fixes the addresses the test expects.
    peer heeler-hs-a-peer a TailnetA
    peer heeler-hs-b-peer b TailnetB
    peer heeler-hs-b-peer2 b TailnetB2
    peer heeler-hs-b-peer3 b TailnetB3
    print_env
    ;;
env)
    print_env
    ;;
down)
    remove_containers
    rm -rf "$WORK"
    ;;
*)
    echo "usage: $0 up|env|down" >&2
    exit 2
    ;;
esac
