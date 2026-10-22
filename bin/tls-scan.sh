#!/bin/bash
# tls-scan.sh — liệt kê mọi cổng TCP đang nghe trên máy, cho biết cổng nào phục vụ cert của domain: MỚI, CŨ hay cert khác.
# CHỈ ĐỌC: không restart, không sửa gì. Cổng ghi "CŨ" là ứng viên cần restart để nạp cert mới.
CFG_DIR="${CFG_DIR:-/etc/caddy-cert-sync}"
source "$CFG_DIR/config.conf" 2>/dev/null || { echo "Không đọc được $CFG_DIR/config.conf"; exit 2; }
want="${WANT:-$(cat "$STATE_DIR/staged/serial" 2>/dev/null)}"
[ -n "$want" ] || { echo "Chưa có serial mong muốn (staged/serial). Đặt WANT=<serial> hoặc chạy stage trước."; exit 2; }

raw=""
if [ -n "${PORTS:-}" ]; then list="$PORTS"
else
    raw=$(ss -tlnpH 2>/dev/null)
    [ -n "$raw" ] || { echo "Không liệt kê được cổng đang nghe (cần lệnh ss và quyền root)"; exit 2; }
    list=$(echo "$raw" | awk '{n=split($4,a,":"); print a[n]}' | sort -un)
fi
proc_of() { echo "$raw" | awk -v p=":$1" '$4 ~ (p "$")' | grep -o '(("[^"]*"' | head -1 | sed 's/(("//; s/"//'; }

printf '%-6s %-16s %s\n' "CỔNG" "TIẾN TRÌNH" "TÌNH TRẠNG"
new=0; old=0; other=0; plain=0; oldports=""
for p in $list; do
    pem=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:"$p" -servername "$DOMAIN" 2>/dev/null | openssl x509 2>/dev/null)
    name=$(proc_of "$p"); name="${name:--}"
    if [ -z "$pem" ]; then
        st="không TLS (hoặc không trả cert)"; plain=$((plain + 1))
    else
        ser=$(printf '%s' "$pem" | openssl x509 -noout -serial | cut -d= -f2)
        info=$(printf '%s' "$pem" | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null)
        if [ "$ser" == "$want" ]; then
            st="MỚI (đúng serial mong muốn)"; new=$((new + 1))
        elif printf '%s' "$info" | grep -qF "$DOMAIN"; then
            st="CŨ: cert của $DOMAIN nhưng serial ${ser:0:12}... -> ứng viên cần restart"; old=$((old + 1)); oldports="$oldports $p($name)"
        else
            st="cert khác ($(printf '%s' "$info" | sed -n 's/^subject=//p' | cut -c1-40)), không phải của $DOMAIN"; other=$((other + 1))
        fi
    fi
    printf '%-6s %-16s %s\n' "$p" "$name" "$st"
done
printf '\nTổng: %d cổng MỚI, %d cổng CŨ của domain, %d cổng cert khác, %d cổng không TLS\n' "$new" "$old" "$other" "$plain"
[ "$old" -eq 0 ] && echo "Không cổng nào còn giữ cert cũ của domain." || echo "Cổng còn giữ cert cũ:${oldports}"
[ "$old" -eq 0 ]
