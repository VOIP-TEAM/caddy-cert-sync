#!/bin/bash
# renew-status.sh — kiểm tra Caddy đang được cấu hình renew khi còn bao nhiêu ngày. CHỈ ĐỌC.
CFG_DIR="${CFG_DIR:-/etc/caddy-cert-sync}"
source "$CFG_DIR/config.conf" 2>/dev/null
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
ADMIN="${ADMIN:-localhost:2019}"
CERT_BASE="${CERT_BASE:-${CADDY_CERT_BASE:-/var/lib/caddy/.local/share/caddy}/certificates}"
JOURNAL_CMD="${JOURNAL_CMD:-journalctl -u caddy --no-pager}"
D=$((86400))

echo "== 1. Caddyfile ($CADDYFILE)"
grep -nE '^[[:space:]]*renewal_window_ratio' "$CADDYFILE" 2>/dev/null || echo "Không có dòng renewal_window_ratio (Caddy dùng mặc định 1/3 vòng đời, khoảng 30 ngày với cert 90 ngày)"

echo; echo "== 2. Giá trị Caddy đang chạy với (Admin API $ADMIN)"
ratio=""
pol=$(curl -s -m 5 "http://$ADMIN/config/apps/tls/automation/policies" 2>/dev/null)
if printf '%s' "$pol" | jq -e 'type=="array"' >/dev/null 2>&1; then
    ratio=$(printf '%s' "$pol" | jq -r '[.[] | .renewal_window_ratio // empty] | first // empty')
    if [ -n "$ratio" ]; then echo "renewal_window_ratio = $ratio"; else echo "Không đặt: Caddy dùng mặc định 1/3"; fi
else
    echo "Không đọc được Admin API ở $ADMIN (Caddy không chạy, hoặc Admin API đã đổi địa chỉ hoặc tắt)"
fi

echo; echo "== 3. Biến trong config.conf (chỉ là con số, tự nó không làm Caddy đổi gì)"
grep -E '^(RENEW_DAYS_BEFORE_EXPIRY|CERT_LIFETIME_DAYS)=' "$CFG_DIR/config.conf" 2>/dev/null || echo "Không có biến nào"

echo; echo "== 4. Cơ chế cũ: script chạy lúc Caddy khởi động (ExecStartPost)"
ls /etc/systemd/system/caddy.service.d/ 2>/dev/null | sed 's/^/file: /'
grep -n -i "renew" /etc/systemd/system/caddy.service.d/*.conf 2>/dev/null
[ -x /usr/local/bin/apply-renew-threshold.sh ] && echo "Còn script cũ /usr/local/bin/apply-renew-threshold.sh" || echo "Không còn apply-renew-threshold.sh"

echo; echo "== 5. Cert hiện tại và ngày Caddy sẽ renew"
crt=$(find "$CERT_BASE" -type f -name "${DOMAIN:-*}.crt" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
if [ -z "$crt" ]; then echo "Không thấy file cert dưới $CERT_BASE"; exit 0; fi
s=$(date -d "$(openssl x509 -noout -startdate -in "$crt" | cut -d= -f2)" +%s); e=$(date -d "$(openssl x509 -noout -enddate -in "$crt" | cut -d= -f2)" +%s)
now=$(date +%s); life=$((e - s))
echo "Cert: $(basename "$crt"), cấp $(date -d @$s '+%F'), hết hạn $(date -d @$e '+%F'), vòng đời $((life / D)) ngày, còn $(((e - now) / D)) ngày"
echo "Nhà cấp: $(openssl x509 -noout -issuer -in "$crt" | sed 's/^issuer=//')"
r="${ratio:-0.3333333333}"
rd=$(awk -v e="$e" -v l="$life" -v r="$r" 'BEGIN{printf "%d", e - l*r}')
echo "Theo ngưỡng (ratio ${ratio:-mặc định 1/3}): renew khi còn $(awk -v l="$life" -v r="$r" -v d="$D" 'BEGIN{printf "%.0f", l*r/d}') ngày, tức từ $(date -d @$rd '+%F %T')"
L=$($JOURNAL_CMD 2>/dev/null | grep -a "renewal info" | tail -1)
ari=$(printf '%s' "$L" | grep -o '"window_start":[0-9]*' | head -1 | cut -d: -f2)
if [ -n "$ari" ]; then
    echo "Theo ARI của nhà cấp: cửa sổ bắt đầu $(date -d @$ari '+%F %T'), tức còn $(((e - ari) / D)) ngày"
    if [ "$ari" -lt "$rd" ]; then who="ARI"; first=$ari; else who="ngưỡng đã đặt"; first=$rd; fi
    echo "=> Caddy renew ở mốc SỚM hơn: $who, từ $(date -d @$first '+%F %T') (còn $(((e - first) / D)) ngày)"
    [ "$who" == "ARI" ] && [ -n "$ratio" ] && echo "   Ngưỡng đã đặt không sớm hơn ARI nên KHÔNG có tác dụng."
else
    echo "Không tìm thấy dòng 'renewal info' trong log Caddy (cert mới, log đã xoay, hoặc nhà cấp không cung cấp ARI); chỉ có mốc theo ngưỡng ở trên"
fi
