#!/bin/bash
# install.sh — cài hoặc nâng cấp từ thư mục mã nguồn. Chạy lại nhiều lần đều an toàn.
#   sudo ./install.sh --profile ten-server        cài, lấy cấu hình từ profiles/ten-server/config.conf (nếu server chưa có)
#   sudo ./install.sh --enable                    bật dịch vụ và timer sau khi đã điền telegram.conf, sbc.cred
#   sudo ./install.sh --agent                     cài agent trên VM PBX (khi hệ thống chạy ở VM khác và thay cert PBX qua SSH)
# Không bao giờ ghi đè config.conf, telegram.conf, sbc.cred đã có trên server.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
DESTDIR="${DESTDIR:-}"
PROFILE=""; ENABLE=0; NEWSECRETS=0; AGENT=0
usage() { sed -n '2,7p' "$0"; exit "${1:-1}"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) [ $# -ge 2 ] || usage; PROFILE="$2"; shift 2 ;;
        --enable)  ENABLE=1; shift ;;
        --agent)   AGENT=1; shift ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done
if [ "$AGENT" -eq 1 ]; then
    install -d -m 755 "$DESTDIR/usr/local/bin" "$DESTDIR/etc"
    install -m 755 "$REPO/bin/pbx-agent.sh" "$DESTDIR/usr/local/bin/pbx-agent.sh"
    if [ ! -f "$DESTDIR/etc/pbx-cert-agent.conf" ]; then
        install -m 640 "$REPO/config/pbx-cert-agent.conf.example" "$DESTDIR/etc/pbx-cert-agent.conf"
        echo "Đã tạo /etc/pbx-cert-agent.conf: kiểm tra PBX_CRT, PBX_KEY, PBX_RESTART_CONTAINERS cho khớp VM PBX này"
    else echo "Giữ nguyên /etc/pbx-cert-agent.conf đã có"; fi
    cat <<'MSG'
Đã cài agent. Bước tiếp trên VM PBX:
  1. Thêm khoá công khai của VM điều khiển vào ~/.ssh/authorized_keys của tài khoản dùng để thay cert (thường là root), MỘT dòng, ví dụ:
       restrict,command="/usr/local/bin/pbx-agent.sh",from="IP-VM-điều-khiển" ssh-ed25519 AAAA... cert-sync
     Khoá này chỉ chạy được đúng agent, không có shell.
  2. Nếu dùng root: đặt PermitRootLogin forced-commands-only trong /etc/ssh/sshd_config rồi reload sshd.
  3. Từ VM điều khiển, kiểm tra: ssh -i <khoá> user@IP-PBX ping   (phải in: pbx-agent ok)
MSG
    echo "Đã cài phiên bản $(cat "$REPO/VERSION") của agent."
    exit 0
fi
if [ ! -d "$REPO/systemd" ]; then
    echo "LỖI: gói này chỉ có agent (dành cho VM PBX khi khác VM). Dùng: sudo ./install.sh --agent"; exit 1
fi
if [ -n "$PROFILE" ] && [ ! -f "$REPO/profiles/$PROFILE/config.conf" ]; then
    echo "LỖI: không có profiles/$PROFILE/config.conf. Các hồ sơ hiện có:"; ls "$REPO/profiles" | grep -v README; exit 1
fi
BIN="$DESTDIR/usr/local/bin"; UNIT="$DESTDIR/etc/systemd/system"; CFG="$DESTDIR/etc/caddy-cert-sync"; SHARE="$DESTDIR/usr/local/share/caddy-cert-sync"
install -d -m 755 "$BIN" "$UNIT" "$CFG" "$SHARE"

for f in "$REPO"/bin/*.sh; do
    mode=755; case "$(basename "$f")" in lib-*) mode=644 ;; esac
    install -m "$mode" "$f" "$BIN/"
done
for f in "$REPO"/systemd/*.service "$REPO"/systemd/*.timer; do install -m 644 "$f" "$UNIT/"; done
install -m 644 "$REPO/VERSION" "$SHARE/VERSION"

if [ ! -f "$CFG/config.conf" ]; then
    src="$REPO/config/config.conf.example"; [ -n "$PROFILE" ] && src="$REPO/profiles/$PROFILE/config.conf"
    install -m 644 "$src" "$CFG/config.conf"; echo "Đã tạo $CFG/config.conf từ ${src#"$REPO"/}"
elif [ -n "$PROFILE" ] && ! cmp -s "$REPO/profiles/$PROFILE/config.conf" "$CFG/config.conf"; then
    install -m 644 "$REPO/profiles/$PROFILE/config.conf" "$CFG/config.conf.new"
    echo "Server đã có config.conf (giữ nguyên). Bản của hồ sơ lưu ở $CFG/config.conf.new, xem khác biệt: diff $CFG/config.conf $CFG/config.conf.new"
fi
for s in telegram.conf sbc.cred; do
    [ -f "$CFG/$s" ] || { install -m 600 "$REPO/config/$s.example" "$CFG/$s"; NEWSECRETS=1; echo "Đã tạo $CFG/$s (quyền 600), cần điền giá trị thật"; }
done

if [ -z "$DESTDIR" ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    if [ "$ENABLE" -eq 1 ]; then
        systemctl enable --now caddy-cert-sync.service caddy-cert-apply.timer caddy-cert-stuck-check.timer caddy-cert-sync-watchdog.timer caddy-cert-expiry-check.timer
    else
        systemctl try-restart caddy-cert-sync.service || true     # nạp bản mới nếu dịch vụ đang chạy
    fi
fi
echo "Đã cài phiên bản $(cat "$REPO/VERSION")."
[ "$NEWSECRETS" -eq 0 ] || echo "Bước tiếp: điền telegram.conf và sbc.cred, kiểm tra cert-deploy.sh status, rồi chạy lại với --enable."
