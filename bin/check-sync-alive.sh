#!/bin/bash
set -uo pipefail
CFG_DIR="${CFG_DIR:-/etc/caddy-cert-sync}"
source "$CFG_DIR/config.conf"
source "${LIB_DIR:-/usr/local/bin}/lib-notify.sh"
if ! systemctl is-active --quiet caddy-cert-sync; then
    notify_telegram "$(printf '<b>CẢNH BÁO: caddy-cert-sync đã dừng</b>\nCert renew sẽ KHÔNG được chuẩn bị và áp dụng cho tới khi khởi động lại.\nKhắc phục: sudo systemctl restart caddy-cert-sync')"
    echo "$(date '+%F %T') - CẢNH BÁO: caddy-cert-sync không chạy" >> "$LOG"
fi
