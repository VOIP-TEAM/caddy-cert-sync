#!/bin/bash
# Gọi pbx-agent.sh trên VM PBX: tại chỗ (mặc định) hoặc qua SSH khi đặt PBX_SSH="user@host".
# Trả mã thoát của agent; 255 là lỗi kết nối SSH, 124 là quá thời gian (PBX_AGENT_TIMEOUT, mặc định 420 giây).
# Tuỳ chọn SSH: PBX_SSH_KEY (khoá riêng) và PBX_SSH_OPTS (mặc định bên dưới; cần known_hosts đã có sẵn host này).
pbx_agent() {
    local t="${PBX_AGENT_TIMEOUT:-420}" opts key=""
    if [ -n "${PBX_SSH:-}" ]; then
        opts="${PBX_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=yes}"
        [ -n "${PBX_SSH_KEY:-}" ] && key="-i $PBX_SSH_KEY"
        # shellcheck disable=SC2086
        timeout "$t" ssh $opts $key "$PBX_SSH" "$*"
    else
        PBX_CRT="${PBX_CRT:-}" PBX_KEY="${PBX_KEY:-}" PORTSIP_UID="${PORTSIP_UID:-888}" PORTSIP_GID="${PORTSIP_GID:-888}" \
            PBX_RESTART_CONTAINERS="${PBX_RESTART_CONTAINERS:-}" timeout "$t" bash "${PBX_AGENT_BIN:-${LIB_DIR:-/usr/local/bin}/pbx-agent.sh}" "$@"
    fi
}
