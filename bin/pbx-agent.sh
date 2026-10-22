#!/bin/bash
# pbx-agent.sh — chạy TRÊN VM PBX. Chỉ làm đúng các việc cần để thay cert cho PBX. Dùng làm "lệnh bắt buộc" của khoá SSH,
# nên người giữ khoá chỉ gọi được các lệnh dưới đây, không có shell.
#   ping                 kiểm tra agent chạy được
#   put crt | put key    nhận nội dung từ stdin vào file tạm cạnh file đích (<đích>.new), in "ok <sha256>"
#   commit               kiểm tra cặp mới (đọc được, khoá khớp cert), sao lưu cặp cũ thành <đích>.prev, rồi đổi tên cặp mới vào
#   restart              docker restart -t 300 các container trong PBX_RESTART_CONTAINERS
#   rollback             khôi phục cặp cũ từ <đích>.prev
#   abort                xoá file tạm .new
# Cấu hình: /etc/pbx-cert-agent.conf (PBX_CRT, PBX_KEY, PORTSIP_UID, PORTSIP_GID, PBX_RESTART_CONTAINERS).
set -uo pipefail
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    # Chạy qua SSH: chỉ tin cấu hình tại chỗ, bỏ mọi biến cấu hình truyền từ ngoài vào
    unset PBX_CRT PBX_KEY PORTSIP_UID PORTSIP_GID PBX_RESTART_CONTAINERS
    CMD="$SSH_ORIGINAL_COMMAND"
else
    CMD="$*"
fi
if [ -z "${PBX_CRT:-}" ] || [ -z "${PBX_KEY:-}" ]; then
    # shellcheck disable=SC1090
    source "${AGENT_CONF:-/etc/pbx-cert-agent.conf}" 2>/dev/null || { echo "agent: không đọc được cấu hình ${AGENT_CONF:-/etc/pbx-cert-agent.conf}" >&2; exit 4; }
fi
: "${PORTSIP_UID:=888}" "${PORTSIP_GID:=888}"
log()  { echo "$(date '+%F %T') - $*" >> "${AGENT_LOG:-/var/log/pbx-cert-agent.log}" 2>/dev/null || true; }
fail() { echo "agent: $1" >&2; log "LỖI: $1"; exit "${2:-1}"; }
{ exec 9> "${AGENT_LOCK:-/var/lock/pbx-cert-agent.lock}"; } 2>/dev/null && { flock -w 30 9 || fail "đang có lệnh khác chạy trên VM PBX" 5; }

read -r op arg _ <<< "$CMD"
case "${op:-}" in
    ping) echo "pbx-agent ok" ;;
    put)
        case "${arg:-}" in
            crt) dst="$PBX_CRT.new" ;;
            key) dst="$PBX_KEY.new" ;;
            *) fail "put chỉ nhận crt hoặc key" 2 ;;
        esac
        mkdir -p "$(dirname "$dst")" 2>/dev/null
        ( umask 077; cat > "$dst" ) 2>/dev/null || { rm -f "$dst"; fail "không ghi được $dst (quyền hoặc ổ đĩa)"; }
        [ -s "$dst" ] || { rm -f "$dst"; fail "nội dung $arg rỗng"; }
        echo "ok $(sha256sum < "$dst" | cut -d' ' -f1)"
        ;;
    commit)
        for f in "$PBX_CRT.new" "$PBX_KEY.new"; do [ -s "$f" ] || fail "thiếu $f (chưa put)"; done
        openssl x509 -noout -in "$PBX_CRT.new" 2>/dev/null || fail "cert mới không đọc được"
        openssl pkey -noout -in "$PBX_KEY.new" 2>/dev/null || fail "khoá mới không đọc được"
        [ "$(openssl x509 -noout -pubkey -in "$PBX_CRT.new" | sha256sum)" == "$(openssl pkey -pubout -in "$PBX_KEY.new" | sha256sum)" ] \
            || fail "khoá mới không khớp cert mới"
        for f in "$PBX_CRT" "$PBX_KEY"; do
            if [ -e "$f" ]; then
                chown --reference="$f" "$f.new" && chmod --reference="$f" "$f.new" || fail "không đặt được chủ và quyền cho $f.new"
            else
                chown "$PORTSIP_UID:$PORTSIP_GID" "$f.new" && chmod 600 "$f.new" || fail "không đặt được chủ $PORTSIP_UID:$PORTSIP_GID cho $f.new"
            fi
        done
        for f in "$PBX_CRT" "$PBX_KEY"; do
            if [ -e "$f" ]; then cp -p "$f" "$f.prev" || fail "không sao lưu được $f"; else rm -f "$f.prev"; fi
        done
        mv -f "$PBX_KEY.new" "$PBX_KEY" && mv -f "$PBX_CRT.new" "$PBX_CRT" && sync || fail "không đổi tên được file mới vào $PBX_CRT, $PBX_KEY"
        log "commit: đã thay $PBX_CRT và $PBX_KEY (bản cũ ở .prev)"
        echo ok
        ;;
    restart)
        [ -n "${PBX_RESTART_CONTAINERS:-}" ] || fail "chưa cấu hình PBX_RESTART_CONTAINERS"
        log "restart: $PBX_RESTART_CONTAINERS"
        # shellcheck disable=SC2086
        docker restart -t 300 $PBX_RESTART_CONTAINERS 2>&1 9>&- || fail "docker restart lỗi"
        ;;
    rollback)
        [ -e "$PBX_CRT.prev" ] && [ -e "$PBX_KEY.prev" ] || fail "không có bản cũ để hoàn tác" 3
        mv -f "$PBX_KEY.prev" "$PBX_KEY" && mv -f "$PBX_CRT.prev" "$PBX_CRT" && sync || fail "không khôi phục được bản cũ"
        log "rollback: đã khôi phục bản cũ"
        echo ok
        ;;
    abort) rm -f "$PBX_CRT.new" "$PBX_KEY.new"; echo ok ;;
    *) fail "lệnh không hợp lệ: ${op:-rỗng}" 2 ;;
esac
