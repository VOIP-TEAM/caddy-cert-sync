#!/bin/bash
# health-check.sh — kiểm tra sức khoẻ hệ thống thay cert PortSIP. CHỈ ĐỌC: không restart, không sửa, không gửi Telegram
CFG_DIR="${CFG_DIR:-/etc/caddy-cert-sync}"
source "$CFG_DIR/config.conf" 2>/dev/null || { echo "Không đọc được $CFG_DIR/config.conf"; exit 2; }
WARN_DAYS="${WARN_DAYS:-14}"; DISK_WARN="${DISK_WARN:-85}"; DISK_FAIL="${DISK_FAIL:-95}"
SBC_LOG="${SBC_LOG:-/var/lib/portsip/sbc/log/portsbc.log}"
ok=0; warn=0; fail=0
OK()   { printf '[OK]        %s\n' "$*"; ok=$((ok+1)); }
WARN() { printf '[CẢNH BÁO]  %s\n' "$*"; warn=$((warn+1)); }
FAIL() { printf '[LỖI]       %s\n' "$*"; fail=$((fail+1)); }
sec()  { printf '\n== %s\n' "$*"; }
days_left() { local e; e=$(openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2); [ -n "$e" ] && echo $(( ($(date -d "$e" +%s) - $(date +%s)) / 86400 )); }
live_cert() { local hp="$1"; case "$hp" in *:*) ;; *) hp="127.0.0.1:$hp" ;; esac; echo | timeout 8 openssl s_client -connect "$hp" -servername "${SNI:-$DOMAIN}" 2>/dev/null | openssl x509 2>/dev/null; }
grp_sni() { case "$1" in PBX) echo "${PBX_SNI:-$DOMAIN}" ;; SBC) echo "${SBC_SNI:-${SBC_TLS_DOMAIN:-$DOMAIN}}" ;; esac; }

sec "Dịch vụ systemd"
if [ ! -d "${SYSTEMD_RUN_DIR:-/run/systemd/system}" ]; then
    echo "(không có systemd, ví dụ đang chạy trong container: bỏ qua kiểm tra dịch vụ và timer systemd)"
else
    svc="caddy-cert-sync"; [ "${USE_CADDY:-true}" == "false" ] || svc="caddy $svc"
    [ "${USE_CADDY:-true}" == "false" ] && echo "(USE_CADDY=false: bỏ qua kiểm tra dịch vụ caddy)"
    for s in $svc; do
        a=$(systemctl is-active "$s" 2>&1); e=$(systemctl is-enabled "$s" 2>&1)
        if   [ "$a" != active ];  then FAIL "$s không chạy ($a)"
        elif [ "$e" != enabled ]; then WARN "$s đang chạy nhưng chưa enable (mất sau khi reboot)"
        else OK "$s đang chạy, đã enable"; fi
    done
    for s in caddy-cert-apply.timer caddy-cert-stuck-check.timer caddy-cert-sync-watchdog.timer caddy-cert-expiry-check.timer; do
        a=$(systemctl is-active "$s" 2>&1); e=$(systemctl is-enabled "$s" 2>&1)
        if [ "$a" == active ] && [ "$e" == enabled ]; then OK "$s active, enabled"; else WARN "$s: $a / $e"; fi
    done

    if [ -n "${RENEW_TIMER_UNIT:-}" ]; then
        a=$(systemctl is-active "$RENEW_TIMER_UNIT" 2>&1); e=$(systemctl is-enabled "$RENEW_TIMER_UNIT" 2>&1)
        if [ "$a" == active ] && [ "$e" == enabled ]; then OK "$RENEW_TIMER_UNIT (xin cert) active, enabled"; else FAIL "$RENEW_TIMER_UNIT (xin cert): $a / $e, sẽ không có cert mới"; fi
    fi
fi

sec "Cert của Caddy và trạng thái chuẩn bị"
src=$(find "$CADDY_CERT_BASE/certificates" -type f -name "$DOMAIN.crt" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
if [ -z "$src" ]; then FAIL "Không thấy $DOMAIN.crt dưới $CADDY_CERT_BASE/certificates"
else
    d=$(days_left < "$src"); iss=$(openssl x509 -noout -issuer -in "$src" 2>/dev/null | sed 's/^issuer=//')
    if   echo "$iss" | grep -qi staging; then FAIL "Cert của Caddy là STAGING ($iss)"
    elif [ "${d:-0}" -lt 3 ];            then FAIL "Cert của Caddy chỉ còn ${d:-0} ngày"
    elif [ "$d" -lt "$WARN_DAYS" ];      then WARN "Cert của Caddy còn $d ngày (renew chưa xảy ra?)"
    else OK "Cert của Caddy còn $d ngày ($iss)"; fi
fi
want=$(cat "$STATE_DIR/staged/serial" 2>/dev/null)
[ -n "$want" ] && OK "Đã chuẩn bị cert serial=$want" || WARN "Chưa có cert nào được chuẩn bị (staged/)"
if [ -f "$STATE_DIR/pending" ]; then
    pd=$(grep '^detected=' "$STATE_DIR/pending" | cut -d= -f2-); ph=$(( ($(date +%s) - $(stat -c %Y "$STATE_DIR/pending")) / 3600 ))
    minD=""
    if [ -n "${DEPLOY_WHEN_DAYS_LEFT:-}" ]; then
        for grp in PBX SBC; do
            eval "ports=\${${grp}_PORTS:-}"; sni=$(grp_sni "$grp")
            for p in $ports; do
                pem=$(SNI="$sni" live_cert "$p"); [ -z "$pem" ] && { minD=""; break 2; }
                d=$(printf '%s' "$pem" | days_left); if [ -z "$minD" ] || [ "$d" -lt "$minD" ]; then minD=$d; fi
            done
        done
    fi
    if [ -n "${DEPLOY_WHEN_DAYS_LEFT:-}" ] && [ -n "$minD" ] && [ "$minD" -ge "$DEPLOY_WHEN_DAYS_LEFT" ]; then
        OK "Cert đang CHỜ ÁP DỤNG từ $pd theo cấu hình hoãn: chỉ thay khi cert đang dùng còn <= $DEPLOY_WHEN_DAYS_LEFT ngày (hiện còn $minD ngày)"
    elif [ "$ph" -ge "${STUCK_HOURS:-20}" ]; then WARN "Cert đang CHỜ ÁP DỤNG đã $ph giờ (phát hiện $pd)"
    else OK "Cert đang CHỜ ÁP DỤNG từ $pd (bình thường nếu đang ngoài khung giờ)"; fi
fi
if [ -f "$STATE_DIR/stage-fail" ]; then
    sr=$(sed -n 1p "$STATE_DIR/stage-fail"); ss=$(sed -n 2p "$STATE_DIR/stage-fail"); sa=$(( ($(date +%s) - ss) / 60 ))
    if [ "$sa" -ge 30 ]; then FAIL "Không chuẩn bị được cert mới: $sr (đã $sa phút)"; else WARN "Đang không chuẩn bị được cert: $sr ($sa phút, có thể tạm thời)"; fi
fi
for f in "$STATE_DIR"/attempts-* "$STATE_DIR"/stuck-alerted-*; do [ -e "$f" ] && WARN "Có dấu vết sự cố chưa dọn: $(basename "$f")"; done

sec "Cấu hình"
if [ -z "${PBX_PORTS:-}" ]; then FAIL "PBX_PORTS rỗng: PBX bị coi là luôn đúng và sẽ không bao giờ được thay; đặt PBX_PORTS (ví dụ 8887)"; else OK "PBX_PORTS=$PBX_PORTS"; fi
if [ -z "${SBC_PORTS:-}" ]; then FAIL "SBC_PORTS rỗng: SBC bị coi là luôn đúng và sẽ không bao giờ được thay; đặt SBC_PORTS (ví dụ 8883 10443 5065 5067)"; else OK "SBC_PORTS=$SBC_PORTS"; fi

if [ -n "${PBX_SSH:-}" ]; then
    sec "VM PBX qua SSH (${PBX_SSH})"
    # shellcheck disable=SC1091
    source "${LIB_DIR:-/usr/local/bin}/lib-remote.sh" 2>/dev/null
    if ! command -v ssh >/dev/null 2>&1; then FAIL "Không có lệnh ssh"
    elif out=$(pbx_agent ping 2>&1); then OK "VM PBX trả lời agent: $out"
    else FAIL "Không gọi được pbx-agent trên VM PBX: ${out:-không phản hồi} (kiểm tra khoá SSH, known_hosts, firewall cổng 22, agent đã cài chưa)"; fi
    echo "(PBX ở VM khác: bỏ qua kiểm tra container PBX tại chỗ; các container còn lại trên máy này vẫn được liệt kê)"
fi
sec "Container PortSIP"
if ! command -v docker >/dev/null 2>&1; then FAIL "Không có lệnh docker"
else
    names=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^portsip\.' | sort)
    [ -z "$names" ] && FAIL "Không thấy container portsip.* nào"
    for n in $names; do
        read -r st rc hl sa < <(docker inspect -f '{{.State.Status}} {{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.State.StartedAt}}' "$n" 2>/dev/null)
        up=$(( ($(date +%s) - $(date -d "$sa" +%s 2>/dev/null || date +%s)) / 60 ))
        if   [ "$st" != running ];  then FAIL "$n: $st"
        elif [ "$hl" == unhealthy ]; then FAIL "$n: unhealthy (chạy $up phút)"
        elif [ "$hl" == starting ];  then WARN "$n: health đang starting"
        elif [ "${rc:-0}" -gt 0 ];   then WARN "$n: chạy $up phút, đã tự restart $rc lần"
        else OK "$n: chạy $up phút, health=$hl"; fi
    done
    if [ -z "${PBX_SSH:-}" ]; then
        for c in ${PBX_RESTART_CONTAINERS:-}; do echo "$names" | grep -qx "$c" || FAIL "Container cấu hình restart không tồn tại: $c"; done
    fi
    sec "Tiến trình trong SBC (supervisor)"
    if [ "${SBC_DOCKER_CMD:-docker}" == "none" ]; then
        echo "(SBC_DOCKER_CMD=none, SBC ở VM khác: bỏ qua kiểm tra tiến trình SBC; kiểm tra cổng SBC ở phần dưới)"
    else
        out=$(${SBC_DOCKER_CMD:-docker} exec portsip.sbc supervisorctl status 2>&1)
        while read -r line; do
            [ -z "$line" ] && continue
            case "$line" in *RUNNING*) OK "SBC: $(echo "$line" | awk '{print $1, $2}')" ;; *) FAIL "SBC: $line" ;; esac
        done <<< "$out"
    fi
fi

sec "Cổng TLS và cert đang phục vụ"
for grp in PBX SBC; do
    eval "ports=\${${grp}_PORTS:-}"
    for p in $ports; do
        hh=127.0.0.1; pt=$p; case "$p" in *:*) hh=${p%:*}; pt=${p##*:} ;; esac
        if ! timeout 3 bash -c "</dev/tcp/$hh/$pt" 2>/dev/null; then FAIL "$grp :$p không kết nối được (không có tiến trình nghe, hoặc bị chặn)"; continue; fi
        pem=$(SNI="$(grp_sni "$grp")" live_cert "$p"); [ -z "$pem" ] && { FAIL "$grp :$p đang nghe nhưng không trả cert TLS"; continue; }
        serial=$(printf '%s' "$pem" | openssl x509 -noout -serial | cut -d= -f2); d=$(printf '%s' "$pem" | days_left)
        msg="$grp :$p serial=$serial, còn $d ngày"
        if   [ "${d:-0}" -lt 3 ];        then FAIL "$msg"
        elif [ "$d" -lt "$WARN_DAYS" ];  then WARN "$msg"
        elif [ -n "$want" ] && [ "$serial" != "$want" ]; then WARN "$msg, khác cert đã chuẩn bị (có thể đang chờ áp dụng)"
        else OK "$msg"; fi
    done
done

sec "Ổ đĩa"
seen=" "
for m in / /var/lib/docker; do
    read -r use mp < <(df -P "$m" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5, $6}')
    [ -z "${use:-}" ] && continue; case "$seen" in *" $mp "*) continue ;; esac; seen="$seen$mp "
    if   [ "$use" -ge "$DISK_FAIL" ]; then FAIL "$mp đầy $use%"
    elif [ "$use" -ge "$DISK_WARN" ]; then WARN "$mp đầy $use%"
    else OK "$mp dùng $use%"; fi
done

sec "Nhật ký"
since=$(date -d '24 hours ago' '+%F %T')
recent=$(awk -v s="$since" '($1" "$2)>=s' "$LOG" 2>/dev/null | grep -E 'LỖI|THẤT BẠI|CẢNH BÁO')
if [ -z "$recent" ]; then OK "Log hệ thống 24 giờ qua không có lỗi"
else WARN "Log hệ thống 24 giờ qua có $(echo "$recent" | wc -l) dòng lỗi/cảnh báo, 3 dòng gần nhất:"; echo "$recent" | tail -3 | cut -c1-170 | sed 's/^/             /'; fi
if [ -r "$SBC_LOG" ]; then
    bad=$(tail -n 300 "$SBC_LOG" | grep -aE 'Failed opening PEM|Error reading domain chain|Failed to create transport' | tail -3)
    if [ -z "$bad" ]; then OK "portsbc.log (300 dòng cuối) không có lỗi nạp cert"
    else FAIL "portsbc.log có lỗi nạp cert:"; echo "$bad" | cut -c1-170 | sed 's/^/             /'; fi
else WARN "Không đọc được $SBC_LOG"; fi

sec "Cấu hình"
tg="$CFG_DIR/telegram.conf"
if [ -f "$tg" ] && ! grep -q 'ĐIỀN' "$tg"; then OK "telegram.conf đã điền giá trị thật"; else WARN "telegram.conf thiếu hoặc còn giá trị mẫu"; fi
for f in "$tg" "$CFG_DIR/sbc.cred"; do
    if [ ! -f "$f" ]; then WARN "Thiếu $f"
    elif [ "$(stat -c %a "$f")" != 600 ]; then WARN "$f có quyền $(stat -c %a "$f"), cần 600"
    else OK "$(basename "$f") quyền 600"; fi
done

printf '\nTổng: %d OK, %d cảnh báo, %d lỗi\n' "$ok" "$warn" "$fail"
[ "$fail" -eq 0 ]
