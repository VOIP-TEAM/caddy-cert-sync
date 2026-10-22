#!/bin/bash
# entrypoint.sh — thay systemd trong container:
#   - giữ watch-caddy-cert.sh sống (chết thì khởi động lại và báo Telegram)
#   - mỗi 15 phút, chỉ trong khung giờ: cert-deploy.sh apply
#   - mỗi giờ: cert-deploy.sh stuck
#   - 09:00 hằng ngày: cert-deploy.sh expiry
# Dùng đúng /etc/caddy-cert-sync/config.conf của máy chủ (gắn volume), nên không cần cấu hình riêng cho container.
set -uo pipefail
CFG_DIR="${CFG_DIR:-/etc/caddy-cert-sync}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
TICK="${SCHED_TICK:-20}"
# shellcheck disable=SC1091
source "$CFG_DIR/config.conf" || { echo "Không đọc được $CFG_DIR/config.conf (đã gắn volume /etc/caddy-cert-sync chưa?)"; exit 1; }
# shellcheck disable=SC1091
source "$BIN_DIR/lib-notify.sh"
mkdir -p "$(dirname "$LOG")" "$STATE_DIR"; touch "$LOG"
log() { echo "$(date '+%F %T') - $*" >> "$LOG"; }
now() { if [ -n "${SCHED_NOW_CMD:-}" ]; then eval "$SCHED_NOW_CMD"; else date '+%F %H %M'; fi; }   # "YYYY-MM-DD HH MM"

in_window_at() {   # $1 = giờ (00-23); cùng quy tắc với lib-window.sh, kể cả khung vắt qua nửa đêm
    local h=$((10#$1))
    if [ "$WINDOW_START" -le "$WINDOW_END" ]; then [ "$h" -ge "$WINDOW_START" ] && [ "$h" -lt "$WINDOW_END" ]
    else [ "$h" -ge "$WINDOW_START" ] || [ "$h" -lt "$WINDOW_END" ]; fi
}

WPID=""; TAILPID=""
start_watcher() { "$BIN_DIR/watch-caddy-cert.sh" & WPID=$!; log "Container: watcher chạy, PID $WPID"; }
cleanup() { kill "$WPID" "$TAILPID" 2>/dev/null; wait 2>/dev/null; exit 0; }
trap cleanup TERM INT

tail -n 0 -F "$LOG" 2>/dev/null & TAILPID=$!      # để "docker logs" thấy nhật ký
log "Container: khởi động, phiên bản $(cat "$(dirname "$BIN_DIR")/share/caddy-cert-sync/VERSION" 2>/dev/null || echo ?), khung giờ ${WINDOW_START}h-${WINDOW_END}h, múi giờ $(date +%Z)"
start_watcher

last_apply=""; last_stuck=""; last_expiry=""; last_alert=0
while true; do
    if ! kill -0 "$WPID" 2>/dev/null; then
        wait "$WPID" 2>/dev/null; rc=$?
        log "LỖI: watcher dừng (mã $rc), khởi động lại"
        if [ $(( $(date +%s) - last_alert )) -ge 600 ]; then
            last_alert=$(date +%s)
            notify_telegram "$(printf '<b>CẢNH BÁO: watcher trong container đã dừng và được khởi động lại</b>\nDomain: %s\nMã thoát: %s' "$DOMAIN" "$rc")"
        fi
        sleep 2; start_watcher
    fi
    read -r d h m <<< "$(now)"; key="$d $h $m"
    if [ $((10#$m % 15)) -eq 0 ] && [ "$key" != "$last_apply" ] && in_window_at "$h"; then
        last_apply="$key"; "$BIN_DIR/cert-deploy.sh" apply || log "LỖI: apply thoát mã $?"
    fi
    if [ $((10#$m)) -eq 0 ] && [ "$key" != "$last_stuck" ]; then
        last_stuck="$key"; "$BIN_DIR/cert-deploy.sh" stuck || log "LỖI: stuck thoát mã $?"
    fi
    if [ $((10#$h)) -eq 9 ] && [ $((10#$m)) -eq 0 ] && [ "$key" != "$last_expiry" ]; then
        last_expiry="$key"; "$BIN_DIR/cert-deploy.sh" expiry || log "LỖI: expiry thoát mã $?"
    fi
    sleep "$TICK" & wait $!
done
