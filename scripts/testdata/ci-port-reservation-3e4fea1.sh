# shellcheck shell=bash
# Globals are supplied and consumed by the independent test worker that sources this fixture.
# shellcheck disable=SC2034,SC2154
# Frozen allocation protocol from 3e4fea1 (14 ports), also byte-identical
# to 150e1c7 (historical 13 ports) except assign_port_block and block size.
# Kept here so mixed-revision tests work in shallow CI checkouts. Do not
# replace these functions with the current allocator: old runners never
# inspect new reservation names. Tests stub listener probes, not these locks.
port_block_base_default=55222
port_block_count=8
port_block_size=14

write_lock_owner() {
    local lock=$1

    printf '%s' "$lock_owner_token" > "$lock/token"
    printf '%s' "$$" > "$lock/pid"
    printf '%s' "$lock_owner_start" > "$lock/start"
}

lock_is_stale() {
    local lock=$1
    local owner
    local expected_start
    local actual_start

    owner=$(cat "$lock/pid" 2>/dev/null)
    expected_start=$(cat "$lock/start" 2>/dev/null)
    if [[ -z "$owner" || -z "$expected_start" ]]; then
        return 0
    fi
    actual_start=$(ps -o lstart= -p "$owner" 2>/dev/null \
        | sed 's/^ *//; s/ *$//')
    [[ -n "$actual_start" && "$actual_start" == "$expected_start" ]] \
        && return 1
    return 0
}

acquire_claim_guard() {
    local lock=$1
    local description=$2
    local guard="$lock.claiming"
    local attempt

    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if mkdir "$guard" 2>/dev/null; then
            active_claim_guard="$guard"
            printf '%s' "$lock_owner_token" > "$guard/token"
            return 0
        fi
        sleep 0.05
    done
    printf 'Cannot claim %s: another run is changing its lock.\n' \
        "$description" >&2
    printf 'If no gate is starting, report and remove orphaned guard %s manually.\n' \
        "$guard" >&2
    return 1
}

release_claim_guard() {
    local guard=$1
    local token

    token=$(cat "$guard/token" 2>/dev/null)
    if [[ "$token" == "$lock_owner_token" \
        || "$active_claim_guard" == "$guard" ]]; then
        rm -f -- "$guard/token"
        rmdir "$guard"
    fi
    if [[ "$active_claim_guard" == "$guard" ]]; then
        active_claim_guard=""
    fi
}

claim_resource_lock() {
    local lock=$1
    local description=$2
    local owner
    local claim_status=1

    active_resource_lock="$lock"
    if ! acquire_claim_guard "$lock" "$description"; then
        active_resource_lock=""
        return 1
    fi
    if [[ ! -d "$lock" ]]; then
        if mkdir "$lock"; then
            write_lock_owner "$lock"
            claim_status=0
        fi
    elif lock_is_stale "$lock"; then
        owner=$(cat "$lock/pid" 2>/dev/null)
        printf 'Reclaiming the stale lock on %s (owner pid %s is gone)\n' \
            "$description" "${owner:-unknown}" >&2
        rm -rf -- "$lock"
        if mkdir "$lock"; then
            write_lock_owner "$lock"
            claim_status=0
        fi
    fi
    release_claim_guard "$active_claim_guard"
    active_resource_lock=""
    return "$claim_status"
}

release_resource_lock() {
    local lock=$1
    local description=$2
    local token

    [[ -n "$lock" && -d "$lock" ]] || return 0
    if ! acquire_claim_guard "$lock" "$description"; then
        return 1
    fi
    token=$(cat "$lock/token" 2>/dev/null)
    if [[ "$token" == "$lock_owner_token" ]]; then
        rm -rf -- "$lock"
    fi
    release_claim_guard "$active_claim_guard"
}

claim_port_block() {
    local -a bases=()
    local base
    local slot
    local busy
    local port
    local offset
    local lock
    local owner
    local -a rejections=()

    if [[ -n "$port_block_base_override" ]]; then
        bases=("$port_block_base_override")
    else
        for ((slot = 0; slot < port_block_count; slot += 1)); do
            bases+=("$((port_block_base_default + slot * port_block_size))")
        done
    fi

    for base in "${bases[@]}"; do
        lock="$lock_root/block-$base"
        busy=""
        for ((offset = 0; offset < port_block_size; offset += 1)); do
            port=$((base + offset))
            if port_is_busy "$port"; then
                busy+=" $port"
                # A run may move to the next free block, but an orphan from a
                # crashed gate still needs to be visible to the operator. It
                # is reported here and deliberately left untouched.
                describe_port_holder "$port" 1 || true
            fi
        done

        # Recorded as "<base> <kind> <detail...>". The kind is explicit because
        # the two rejections carry different trailing numbers -- ports for one,
        # a pid for the other -- and only ports may be looked up as ports.
        if [[ -n "$busy" ]]; then
            rejections+=("$base ports$busy")
            continue
        fi

        if claim_resource_lock "$lock" "port block $base"; then
            run_lock_dir="$lock"
            assign_port_block "$base"
            return 0
        fi

        owner=$(cat "$lock/pid" 2>/dev/null)
        rejections+=("$base lock ${owner:-unknown}")
    done

    echo "Every fixture port block on this machine is taken." >&2
    echo "The merge gate needs $port_block_size consecutive free ports." >&2
    local -a fields=()
    local rejection
    for rejection in "${rejections[@]}"; do
        read -r -a fields <<<"$rejection"
        if [[ "${fields[1]}" == "ports" ]]; then
            printf '  block %s: ports in use:%s\n' \
                "${fields[0]}" "${rejection#"${fields[0]} ports"}" >&2
            for port in "${fields[@]:2}"; do
                describe_port_holder "$port" || true
            done
        else
            printf '  block %s: claimed by live run pid %s\n' \
                "${fields[0]}" "${fields[2]}" >&2
        fi
    done
    echo >&2
    echo "What to do:" >&2
    echo "  - a block held by a live run: wait for it, or widen" >&2
    echo "    port_block_count in this script." >&2
    echo "  - an ORPHAN above outlived its run. Confirm it is yours, then" >&2
    echo "    kill it by pid. This script never kills what it did not start." >&2
    echo "  - to pin a block yourself: HEELER_CI_PORT_BASE=<base>" >&2
    exit 1
}

assign_port_block() {
    local base=$1
    local highest

    modern_port=$((base + 0))
    legacy_port=$((base + 1))
    restricted_port=$((base + 2))
    stall_port=$((base + 3))
    streamlocal_global_policy_port=$((base + 4))
    streamlocal_key_policy_port=$((base + 5))
    jump_target_port=$((base + 6))
    jump_forwarding_denied_port=$((base + 7))
    pairing_port=$((base + 8))
    password_port=$((base + 9))
    # The unprivileged impairment proxy: a degraded route to the modern sshd,
    # plus the control port the weak-network suite steers it through.
    weak_network_port=$((base + 10))
    weak_network_control_port=$((base + 11))
    # Post-quantum coverage uses a dedicated endpoint so the established
    # resource and timing suites keep exercising their Curve25519 baseline.
    post_quantum_port=$((base + 12))
    # Real herdr-core has its own isolated home and sshd.
    core_port=$((base + 13))

    # Adding a port above without widening port_block_size would overlap the
    # next block, which no test could distinguish from a flaky fixture.
    highest=$core_port
    if [[ "$highest" -ne "$((base + port_block_size - 1))" ]]; then
        echo "assign_port_block assigns past port_block_size=$port_block_size" >&2
        exit 1
    fi
}

historical_assign_port_block() {
    local base=$1
    local highest

    modern_port=$((base + 0))
    legacy_port=$((base + 1))
    restricted_port=$((base + 2))
    stall_port=$((base + 3))
    streamlocal_global_policy_port=$((base + 4))
    streamlocal_key_policy_port=$((base + 5))
    jump_target_port=$((base + 6))
    jump_forwarding_denied_port=$((base + 7))
    pairing_port=$((base + 8))
    password_port=$((base + 9))
    # The unprivileged impairment proxy: a degraded route to the modern sshd,
    # plus the control port the weak-network suite steers it through.
    weak_network_port=$((base + 10))
    weak_network_control_port=$((base + 11))
    # Post-quantum coverage uses a dedicated endpoint so the established
    # resource and timing suites keep exercising their Curve25519 baseline.
    post_quantum_port=$((base + 12))

    # Adding a port above without widening port_block_size would overlap the
    # next block, which no test could distinguish from a flaky fixture.
    highest=$post_quantum_port
    if [[ "$highest" -ne "$((base + port_block_size - 1))" ]]; then
        echo "assign_port_block assigns past port_block_size=$port_block_size" >&2
        exit 1
    fi
}
