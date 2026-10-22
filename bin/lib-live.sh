#!/bin/bash
# Đo cert mà các cổng đang THỰC SỰ phục vụ (nguồn sự thật để biết đã áp dụng hay chưa)
log() { echo "$(date '+%F %T') - $*" >> "$LOG"; }

# Mục cổng có thể là "8887" (máy này, 127.0.0.1) hoặc "10.0.0.2:8883" (máy khác, ví dụ VM SBC).
# SNI lấy từ biến SNI (nếu đặt) hoặc DOMAIN.
hostport() { case "$1" in *:*) echo "$1" ;; *) echo "127.0.0.1:$1" ;; esac; }

live_serial() {
    echo | timeout 8 openssl s_client -connect "$(hostport "$1")" -servername "${SNI:-$DOMAIN}" 2>/dev/null \
        | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2
}

# ports_report "<cổng>": in "cổng=serial" cho từng cổng (hoặc "không có cert"), dùng để ghi lý do thất bại
ports_report() {
    local p s out=""
    for p in $1; do s=$(live_serial "$p"); out="$out $p=${s:-không có cert}"; done
    echo "${out# }"
}

# min_days_left "<cổng>": số ngày còn lại ít nhất trong các cert mà các cổng đang phục vụ.
# In ra chuỗi rỗng nếu có cổng không đo được (khi đó không nên hoãn việc thay cert)
min_days_left() {
    local p pem e d min=""
    for p in $1; do
        pem=$(echo | timeout 8 openssl s_client -connect "$(hostport "$p")" -servername "${SNI:-$DOMAIN}" 2>/dev/null | openssl x509 2>/dev/null)
        [ -n "$pem" ] || { echo ""; return 0; }
        e=$(printf '%s' "$pem" | openssl x509 -noout -enddate | cut -d= -f2)
        d=$(( ($(date -d "$e" +%s) - $(date +%s)) / 86400 ))
        if [ -z "$min" ] || [ "$d" -lt "$min" ]; then min=$d; fi
    done
    echo "$min"
}

# ports_ok "<danh sách cổng>" <serial mong muốn> : đúng khi MỌI cổng trả đúng serial
ports_ok() {
    local p s
    for p in $1; do
        s=$(live_serial "$p")
        [ -n "$s" ] && [ "$s" == "$2" ] || return 1
    done
    return 0
}

# wait_ports "<cổng>" <serial> <số giây tối đa>
wait_ports() {
    local t=0 step="${POLL:-5}"
    while :; do
        ports_ok "$1" "$2" && return 0
        [ "$t" -ge "$3" ] && return 1
        sleep "$step"; t=$((t + step))
    done
}
