#!/bin/bash
# set-renew-days.sh — đặt "còn bao nhiêu ngày thì Caddy renew" vào Caddyfile (tuỳ chọn toàn cục renewal_window_ratio).
# Đọc RENEW_DAYS_BEFORE_EXPIRY và CERT_LIFETIME_DAYS trong config.conf. Có sao lưu, kiểm tra bằng caddy validate
# trước khi reload, và tự khôi phục nếu lỗi. Dùng --force để đặt cả khi ngưỡng không có tác dụng với Let's Encrypt.
set -uo pipefail
CFG_DIR="${CFG_DIR:-/etc/caddy-cert-sync}"
source "$CFG_DIR/config.conf" 2>/dev/null || { echo "Không đọc được $CFG_DIR/config.conf"; exit 2; }
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
CADDY_BIN="${CADDY_BIN:-caddy}"
RELOAD_CMD="${RELOAD_CMD:-systemctl reload caddy}"
CADDY_ACTIVE_CMD="${CADDY_ACTIVE_CMD:-systemctl is-active --quiet caddy}"
DAYS="${RENEW_DAYS_BEFORE_EXPIRY:-}"; LIFE="${CERT_LIFETIME_DAYS:-90}"
FORCE=0; [ "${1:-}" == "--force" ] && FORCE=1
die() { echo "LỖI: $*"; exit 1; }

[ -n "$DAYS" ] || die "chưa đặt RENEW_DAYS_BEFORE_EXPIRY trong $CFG_DIR/config.conf"
[[ "$DAYS" =~ ^[0-9]+$ && "$LIFE" =~ ^[0-9]+$ ]] || die "RENEW_DAYS_BEFORE_EXPIRY ($DAYS) và CERT_LIFETIME_DAYS ($LIFE) phải là số nguyên"
[ "$DAYS" -ge 1 ] && [ "$DAYS" -lt "$LIFE" ] || die "RENEW_DAYS_BEFORE_EXPIRY phải từ 1 tới $((LIFE - 1)) (đang là $DAYS)"
[ -f "$CADDYFILE" ] || die "không thấy $CADDYFILE"
RATIO=$(awk -v d="$DAYS" -v l="$LIFE" 'BEGIN{printf "%.4f", d/l}')

# Let's Encrypt cung cấp ARI: Caddy renew khi ARI báo đến giờ (khoảng 1/3 vòng đời còn lại) HOẶC khi còn dưới ngưỡng này,
# cái nào đến trước. Ngưỡng nhỏ hơn mốc ARI không làm renew muộn hơn.
if [ $((DAYS * 3)) -le "$LIFE" ] && [ "$FORCE" -ne 1 ]; then
    echo "KHÔNG ĐẶT: còn $DAYS ngày (tỷ lệ $RATIO) không sớm hơn mốc ARI của Let's Encrypt (khoảng $((LIFE / 3)) ngày còn lại),"
    echo "nên Caddy vẫn renew ở mốc ARI và giá trị này không có tác dụng. Muốn renew SỚM hơn thì đặt số ngày lớn hơn $((LIFE / 3))."
    echo "Nếu nhà cấp của bạn không có ARI (ví dụ ZeroSSL) thì chạy lại với --force."
    exit 3
fi

cur=$(grep -E '^[[:space:]]*renewal_window_ratio[[:space:]]+' "$CADDYFILE" | head -1 | awk '{print $2}')
if [ "$cur" == "$RATIO" ]; then echo "Đã đúng sẵn (renewal_window_ratio $RATIO = $DAYS/$LIFE), không đổi gì"; exit 0; fi

TMP=$(mktemp); BAK="$CADDYFILE.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$CADDYFILE" "$BAK" || die "không sao lưu được $CADDYFILE"
if [ -n "$cur" ]; then
    sed -E "s|^([[:space:]]*renewal_window_ratio[[:space:]]+).*|\1$RATIO|" "$CADDYFILE" > "$TMP"
else
    # Khối tuỳ chọn toàn cục phải là khối đầu tiên của Caddyfile; không có thì không tự tạo
    grep -v -E '^[[:space:]]*(#.*)?$' "$CADDYFILE" | head -1 | grep -qE '^[[:space:]]*\{[[:space:]]*$' \
        || { rm -f "$BAK" "$TMP"; die "Caddyfile không bắt đầu bằng khối tuỳ chọn toàn cục '{ ... }'. Thêm tay vào khối đó dòng: renewal_window_ratio $RATIO"; }
    first=$(grep -n -m1 -E '^[[:space:]]*\{[[:space:]]*$' "$CADDYFILE" | cut -d: -f1)
    sed "${first}a\\    renewal_window_ratio $RATIO" "$CADDYFILE" > "$TMP"
fi
cat "$TMP" > "$CADDYFILE"; rm -f "$TMP"      # ghi đè nội dung, giữ nguyên chủ sở hữu và quyền

if ! "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    cat "$BAK" > "$CADDYFILE"
    die "Caddy không chấp nhận cấu hình (bản Caddy quá cũ chưa có renewal_window_ratio?). Đã khôi phục $CADDYFILE"
fi
if $CADDY_ACTIVE_CMD; then
    if ! $RELOAD_CMD; then cat "$BAK" > "$CADDYFILE"; die "reload lỗi, đã khôi phục $CADDYFILE (bản sao lưu: $BAK)"; fi
    echo "Đã đặt renewal_window_ratio $RATIO ($DAYS/$LIFE ngày) và reload Caddy. Bản sao lưu: $BAK"
else
    echo "Đã đặt renewal_window_ratio $RATIO ($DAYS/$LIFE ngày). Caddy đang không chạy nên chưa reload; sẽ có hiệu lực khi khởi động. Bản sao lưu: $BAK"
fi
