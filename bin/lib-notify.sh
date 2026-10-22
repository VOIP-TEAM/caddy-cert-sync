#!/bin/bash
TELEGRAM_CONF="${CFG_DIR:-/etc/caddy-cert-sync}/telegram.conf"

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

notify_telegram() {
    local text="$1" resp
    [ -f "$TELEGRAM_CONF" ] && source "$TELEGRAM_CONF"
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        echo "$(date '+%F %T') - CẢNH BÁO: chưa cấu hình Telegram" >> "$LOG"
        return 0
    fi
    resp=$(curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" -d parse_mode="HTML" --data-urlencode text="$text")
    case "$resp" in
        *'"ok":true'*) ;;
        *) echo "$(date '+%F %T') - CẢNH BÁO: gửi Telegram thất bại: ${resp:0:200}" >> "$LOG" ;;
    esac
    return 0
}
