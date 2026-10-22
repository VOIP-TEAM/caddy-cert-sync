#!/bin/bash
# cert-deploy.sh — chuẩn bị (stage) và áp dụng (apply) cert cho PortSIP PBX + SBC
#   stage  : kiểm tra cert Caddy, chuẩn hoá, lưu vào staged/, gửi [1/2]. KHÔNG đụng PBX/SBC
#   apply  : (timer) chuẩn bị bù nếu cần; CHỈ khi có cert chờ và trong khung giờ mới áp dụng; có giới hạn số lần thử
#            Quy tắc: PBX rồi SBC; một bên lỗi thì hoàn tác CẢ HAI về cert cũ rồi báo Telegram
#   now    : áp dụng ngay (chỉ khi có cert chờ), bỏ qua khung giờ và giới hạn số lần thử; now --force: bỏ cả điều kiện có cert chờ
#   baseline CRT KEY : ghi cặp cert đang chạy làm mốc hoàn tác cho SBC (dùng cho lần thay đầu tiên)
#   status : in dấu CHỜ ÁP DỤNG, serial mong muốn và serial từng cổng đang phục vụ (chỉ đọc)
#   stuck  : cảnh báo nếu cert đã chuẩn bị nhưng quá lâu chưa được áp dụng
#   expiry : cảnh báo Telegram khi cert ĐANG DÙNG sắp hết hạn (mốc trong EXPIRY_ALERT_DAYS, mặc định 30 14 7 3 1)
set -uo pipefail
CFG_DIR="${CFG_DIR:-/etc/caddy-cert-sync}"
LIB_DIR="${LIB_DIR:-/usr/local/bin}"
source "$CFG_DIR/config.conf"
[ -f "$CFG_DIR/sbc.cred" ] && source "$CFG_DIR/sbc.cred"
for l in lib-notify lib-window lib-live lib-sbc-api lib-remote; do source "$LIB_DIR/$l.sh"; done
umask 077

STAGE="$STATE_DIR/staged"
APPLIED="$STATE_DIR/applied"
PENDING="$STATE_DIR/pending"      # dấu "đang chờ áp dụng": có file = có cert mới chưa được thay
MAX_AUTO_ATTEMPTS="${MAX_AUTO_ATTEMPTS:-2}"
WAIT_PBX="${WAIT_PBX:-90}"
WAIT_SBC="${WAIT_SBC:-90}"
mkdir -p "$STATE_DIR"

# PBX và SBC có thể nằm trên hai VM khác nhau: mỗi nhóm đo bằng SNI riêng, mục cổng có thể là host:port.
PBX_SNI_EFF="${PBX_SNI:-$DOMAIN}"
SBC_SNI_EFF="${SBC_SNI:-${SBC_TLS_DOMAIN:-$DOMAIN}}"
pbx_ok()     { SNI="$PBX_SNI_EFF" ports_ok "$PBX_PORTS" "$1"; }
sbc_ok()     { SNI="$SBC_SNI_EFF" ports_ok "$SBC_PORTS" "$1"; }
pbx_wait()   { SNI="$PBX_SNI_EFF" wait_ports "$PBX_PORTS" "$1" "$2"; }
sbc_wait()   { SNI="$SBC_SNI_EFF" wait_ports "$SBC_PORTS" "$1" "$2"; }
pbx_report() { SNI="$PBX_SNI_EFF" ports_report "$PBX_PORTS"; }
sbc_report() { SNI="$SBC_SNI_EFF" ports_report "$SBC_PORTS"; }
# Số ngày còn lại ít nhất của mọi cổng đo được; rỗng nếu có cổng không đo được (khi đó không hoãn)
min_days_all() {
    local a="" b="" ha=0 hb=0
    if [ -n "${PBX_PORTS:-}" ]; then ha=1; a=$(SNI="$PBX_SNI_EFF" min_days_left "$PBX_PORTS"); fi
    if [ -n "${SBC_PORTS:-}" ]; then hb=1; b=$(SNI="$SBC_SNI_EFF" min_days_left "$SBC_PORTS"); fi
    if { [ "$ha" -eq 1 ] && [ -z "$a" ]; } || { [ "$hb" -eq 1 ] && [ -z "$b" ]; }; then echo ""; return; fi
    if   [ "$ha" -eq 0 ]; then echo "$b"
    elif [ "$hb" -eq 0 ]; then echo "$a"
    elif [ "$a" -le "$b" ]; then echo "$a"; else echo "$b"; fi
}

# stage_fail <lý do>: ghi log; nếu CÙNG một lý do kéo dài quá STAGE_ALERT_SECS thì báo Telegram một lần.
# Lỗi tạm thời (Caddy ghi crt trước key) tự hết trước ngưỡng nên không gây báo giả.
stage_fail() {
    local reason="$1" f="$STATE_DIR/stage-fail" since now
    log "STAGE: $reason"
    now=$(date +%s)
    if [ "$(sed -n 1p "$f" 2>/dev/null)" == "$reason" ]; then
        since=$(sed -n 2p "$f")
    else
        since=$now; rm -f "$f.alerted"; printf '%s\n%s\n' "$reason" "$now" > "$f"
    fi
    if [ $((now - since)) -ge "${STAGE_ALERT_SECS:-1800}" ] && [ ! -f "$f.alerted" ]; then
        notify_telegram "$(printf '<b>CẢNH BÁO: không chuẩn bị được cert mới</b>\nDomain: %s\nLý do: %s\nKéo dài từ: %s\nXem log %s rồi chạy: sudo cert-deploy.sh status' \
            "$DOMAIN" "$(printf '%s' "$reason" | esc)" "$(date -d @"$since" '+%F %T')" "$LOG")"
        touch "$f.alerted"
    fi
    return 0
}
stage_ok() { rm -f "$STATE_DIR/stage-fail" "$STATE_DIR/stage-fail.alerted"; }

# Cert mới nhất của domain, ở bất kỳ nhà cấp nào (Let's Encrypt, ZeroSSL...)
find_source() {
    find "$CADDY_CERT_BASE/certificates" -type f -name "$DOMAIN.crt" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d' ' -f2-
}

# Chuỗi sạch: bỏ \r, bỏ dòng trống, bỏ cert gốc tự ký, mỗi khối phải đọc được
normalize_chain() {
    local d f
    d=$(mktemp -d); : > "$2"
    tr -d '\r' < "$1" | awk -v d="$d" '/-----BEGIN CERTIFICATE-----/{n++} n>0 && NF{print > (d "/c" n ".pem")}'
    for f in $(ls "$d"/c*.pem 2>/dev/null | sort -V); do
        openssl x509 -in "$f" -noout 2>/dev/null || { rm -rf "$d"; return 1; }
        [ "$(openssl x509 -in "$f" -noout -subject_hash)" == "$(openssl x509 -in "$f" -noout -issuer_hash)" ] && continue
        openssl x509 -in "$f" >> "$2"
    done
    rm -rf "$d"
    [ -s "$2" ]
}

cmd_stage() {
    local noapply="${1:-}" src key ser issuer N="$STATE_DIR/staged.new"
    src=$(find_source)
    [ -n "$src" ] || { stage_fail "không thấy $DOMAIN.crt dưới $CADDY_CERT_BASE/certificates"; return 0; }
    key="${src%.crt}.key"
    [ -s "$key" ] || { stage_fail "chưa có file khoá $key"; return 0; }
    issuer=$(openssl x509 -noout -issuer -in "$src" 2>/dev/null) || { stage_fail "không đọc được file cert $src"; return 0; }
    case "${issuer,,}" in *staging*) stage_fail "cert của Caddy là cert staging (không dùng được với client thật)"; return 0 ;; esac
    [ "$(openssl x509 -noout -pubkey -in "$src" | sha256sum)" == "$(openssl pkey -pubout -in "$key" 2>/dev/null | sha256sum)" ] \
        || { stage_fail "khoá không khớp cert (Caddy chưa ghi xong, hoặc sai cặp)"; return 0; }
    ser=$(openssl x509 -noout -serial -in "$src" | cut -d= -f2)
    [ "$ser" == "$(cat "$STAGE/serial" 2>/dev/null)" ] && { stage_ok; return 0; }

    rm -rf "$N"; mkdir -p "$N" || { stage_fail "không tạo được thư mục $N (ổ đĩa đầy?)"; return 0; }
    normalize_chain "$src" "$N/chain.pem" || { stage_fail "chuỗi cert hỏng hoặc không đọc được từng khối"; rm -rf "$N"; return 0; }
    cp "$key" "$N/key.raw.pem" && openssl pkey -in "$key" -out "$N/key.pem" 2>/dev/null && echo "$ser" > "$N/serial" \
        && [ -s "$N/chain.pem" ] && [ -s "$N/key.pem" ] && [ -s "$N/key.raw.pem" ] && [ -s "$N/serial" ] \
        || { stage_fail "không ghi đủ các file chuẩn bị (ổ đĩa đầy, hoặc khoá không đọc được)"; rm -rf "$N"; return 0; }
    [ "$(grep -c 'BEGIN CERTIFICATE' "$N/chain.pem")" -ge 2 ] || log "CẢNH BÁO: chuỗi chỉ có 1 cert (thiếu cert trung gian)"
    rm -rf "$STAGE.old"; [ -d "$STAGE" ] && mv "$STAGE" "$STAGE.old"
    mv "$N" "$STAGE"
    log "Đã chuẩn bị cert serial=$ser nguồn=$src"
    stage_ok

    # Caddy đã cấp cert MỚI khi serial khác serial đã thấy lần trước (restart Caddy không đổi serial)
    local prev kind nb dlnote="" dl
    prev=$(cat "$STATE_DIR/last-seen-serial" 2>/dev/null)
    if [ -z "$prev" ]; then kind="Ghi nhận cert hiện có của ${CERT_SOURCE_NAME:-Caddy} (lần đầu)"; else kind="${CERT_SOURCE_NAME:-Caddy} đã cấp cert mới"; fi
    nb=$(openssl x509 -noout -startdate -in "$src" | cut -d= -f2)
    {   echo "serial=$ser"
        echo "detected=$(date '+%F %T')"
        echo "notbefore=$nb"
        echo "issuer=${issuer#issuer=}"
        echo "source=$src"
    } > "$PENDING" || stage_fail "không ghi được dấu chờ $PENDING"
    echo "$ser" > "$STATE_DIR/last-seen-serial"
    log "Đã đánh dấu CHỜ ÁP DỤNG ($kind)"
    if [ -n "${DEPLOY_WHEN_DAYS_LEFT:-}" ]; then
        dl=$(min_days_all)
        [ -n "$dl" ] && dlnote=$(printf '\nSẽ chỉ thay khi cert đang dùng còn %s ngày trở xuống (hiện còn %s ngày).' "$DEPLOY_WHEN_DAYS_LEFT" "$dl")
    fi

    notify_telegram "$(printf '<b>[1/2] %s</b>\nDomain: %s\nSerial: %s\nCấp ngày: %s\nHạn: %s\nNhà cấp: %s\nĐã đánh dấu: CHỜ ÁP DỤNG. Chưa thay cert nào; PBX và SBC sẽ được thay cùng lúc khi áp dụng (khung %02d:00-%02d:00 hoặc chạy tay). Một bên lỗi thì cả hai được hoàn tác về cert cũ.%s' \
        "$kind" "$DOMAIN" "$ser" "$nb" "$(openssl x509 -noout -enddate -in "$src" | cut -d= -f2)" "$(printf '%s' "${issuer#issuer=}" | esc)" "$WINDOW_START" "$WINDOW_END" "$dlnote")"

    if [ -z "$noapply" ] && in_maintenance_window; then cmd_apply "TỰ ĐỘNG"; fi
    return 0
}

# Chép file cho PBX: file đã có thì chỉ ghi đè nội dung (giữ chủ sở hữu và quyền)
# Thay cert PBX qua pbx-agent.sh (tại chỗ hoặc qua SSH): đẩy cặp mới lên cạnh file đích và đối chiếu sha256, kiểm tra khớp khoá,
# sao lưu cặp cũ rồi đổi tên nguyên tử, restart, xác minh bằng serial cổng; lỗi sau khi đã đổi thì luôn hoàn tác.
# Đặt PBX_REASON, PBX_CHANGED (1 nếu file PBX đã bị đổi), PBX_OLD_SERIAL.
pbx_replace() {
    local want="$1" out h1 h2 first
    PBX_REASON=""; PBX_CHANGED=0; PBX_NEEDS_MANUAL=0
    # shellcheck disable=SC2086
    set -- $PBX_PORTS; first="${1:-}"
    PBX_OLD_SERIAL=""; [ -n "$first" ] && PBX_OLD_SERIAL=$(SNI="$PBX_SNI_EFF" live_serial "$first")
    out=$(pbx_agent ping 2>&1) || { PBX_REASON="không nối được VM PBX (${PBX_SSH:-tại chỗ}): ${out:-không có phản hồi}. Chưa thay đổi gì"; return 1; }
    h1=$(sha256sum < "$STAGE/chain.pem" | cut -d' ' -f1); h2=$(sha256sum < "$STAGE/key.raw.pem" | cut -d' ' -f1)
    if ! out=$(pbx_agent put crt < "$STAGE/chain.pem" 2>&1) || [ "${out##* }" != "$h1" ]; then
        pbx_agent abort >/dev/null 2>&1; PBX_REASON="không chép được cert lên VM PBX: ${out:-không rõ}. Chưa thay đổi gì"; return 1; fi
    if ! out=$(pbx_agent put key < "$STAGE/key.raw.pem" 2>&1) || [ "${out##* }" != "$h2" ]; then
        pbx_agent abort >/dev/null 2>&1; PBX_REASON="không chép được khoá lên VM PBX: ${out:-không rõ}. Chưa thay đổi gì"; return 1; fi
    if ! out=$(pbx_agent commit 2>&1); then
        pbx_agent abort >/dev/null 2>&1; PBX_REASON="VM PBX từ chối cặp cert mới: ${out:-không rõ}. Chưa thay đổi gì"; return 1; fi
    PBX_CHANGED=1
    if ! out=$(pbx_agent restart 2>&1); then
        echo "$out" >> "$LOG"
        PBX_REASON="docker restart lỗi trên VM PBX (tên container sai, hoặc docker không chạy; xem log): $(echo "$out" | tail -1)"
    elif ! pbx_wait "$want" "$WAIT_PBX"; then
        local rep; rep=$(pbx_report)
        PBX_REASON="đã restart nhưng cổng PBX chưa phục vụ serial $want sau ${WAIT_PBX}s ($rep)"
        # Một số cổng đã đúng serial mà cổng khác không có cert: nhiều khả năng cổng đó không phải cổng TLS
        case "$rep" in *"=$want"*"không có cert"*|*"không có cert"*"=$want"*)
            PBX_REASON="$PBX_REASON. Cổng nào ghi 'không có cert' có thể không phục vụ TLS (WebSocket thường, hoặc cổng khác): kiểm tra rồi bỏ khỏi PBX_PORTS" ;; esac
    else
        return 0
    fi
    pbx_undo || PBX_NEEDS_MANUAL=1
    PBX_REASON="$PBX_REASON. Hoàn tác:$PBX_UNDO_NOTE"
    return 1
}

# Hoàn tác PBX về cặp cert trước, restart lại và xác minh bằng serial cũ (nếu biết). Đặt PBX_UNDO_NOTE.
pbx_undo() {
    local out rc
    PBX_UNDO_NOTE=""
    out=$(pbx_agent rollback 2>&1); rc=$?
    if [ "$rc" -eq 3 ]; then PBX_UNDO_NOTE=" không có cert cũ để hoàn tác (lần đầu): file PBX đang là cert mới nhưng PBX chưa phục vụ nó. CẦN KIỂM TRA TAY VM PBX."; return 1; fi
    if [ "$rc" -ne 0 ]; then PBX_UNDO_NOTE=" KHÔNG làm được (${out:-không rõ}). CẦN KIỂM TRA TAY VM PBX."; return 1; fi
    if ! out=$(pbx_agent restart 2>&1); then echo "$out" >> "$LOG"; PBX_UNDO_NOTE=" đã khôi phục file cũ nhưng restart lại lỗi. CẦN KIỂM TRA TAY VM PBX."; return 1; fi
    if [ -z "${PBX_OLD_SERIAL:-}" ]; then PBX_UNDO_NOTE=" đã khôi phục file cũ và restart (không biết serial cũ nên không xác minh được)."; return 0; fi
    if SNI="$PBX_SNI_EFF" wait_ports "$PBX_PORTS" "$PBX_OLD_SERIAL" "$WAIT_PBX"; then
        PBX_UNDO_NOTE=" PBX đã phục vụ lại cert trước (serial $PBX_OLD_SERIAL)."; return 0
    fi
    PBX_UNDO_NOTE=" đã khôi phục file cũ và restart nhưng cổng PBX chưa phục vụ lại serial $PBX_OLD_SERIAL. CẦN KIỂM TRA TAY VM PBX."; return 1
}
keep_applied() { rm -rf "$APPLIED"; cp -a "$STAGE" "$APPLIED"; }

apply_sbc() {
    local want="$1" svc first_resp rep rolled="" oldser
    SBC_REASON=""; SBC_NEEDS_MANUAL=0; SBC_TOUCHED=0
    sbc_login || {
        log "SBC: đăng nhập API thất bại: ${SBC_LOGIN_INFO:-không có thông tin}"
        SBC_REASON="đăng nhập API thất bại (${SBC_LOGIN_INFO:-không có thông tin}). Kiểm tra mật khẩu trong sbc.cred và SBC_TOKEN_JQ"
        return 1
    }
    SBC_TOUCHED=1
    [ "${SBC_DELETE_FIRST:-true}" == "true" ] && sbc_delete
    sbc_add "$STAGE"; first_resp="${SBC_LAST_RESP:-}"
    sbc_wait "$want" "$WAIT_SBC" && { keep_applied; return 0; }
    # Restart dự phòng trong container SBC. SBC_DOCKER_CMD: "docker" (SBC cùng máy, mặc định),
    # "ssh user@vm-sbc docker" (SBC ở VM khác), hoặc "none" (bỏ qua, chỉ dựa vào API).
    if [ "${SBC_DOCKER_CMD:-docker}" != "none" ]; then
        for svc in ${SBC_FALLBACK_RESTART:-nginx}; do
            log "SBC: chưa thấy cert mới, restart $svc trong container"
            ${SBC_DOCKER_CMD:-docker} exec portsip.sbc supervisorctl restart "$svc" >> "$LOG" 2>&1
            sbc_wait "$want" "${WAIT_FALLBACK:-60}" && { keep_applied; return 0; }
        done
    fi
    rep=$(sbc_report)
    if [ -f "$APPLIED/chain.pem" ]; then
        log "SBC: hoàn tác về cert trước đó"; sbc_delete; sbc_add "$APPLIED"
        oldser=$(openssl x509 -noout -serial -in "$APPLIED/chain.pem" 2>/dev/null | cut -d= -f2)
        if [ -n "$oldser" ] && sbc_wait "$oldser" "$WAIT_SBC"; then rolled=" Đã hoàn tác: SBC phục vụ lại cert trước (serial $oldser)."
        else rolled=" Hoàn tác SBC KHÔNG xác minh được (đã AddCert lại cert trước nhưng cổng chưa phục vụ serial ${oldser:-không rõ}). CẦN KIỂM TRA TAY SBC."; SBC_NEEDS_MANUAL=1; fi
    else
        rolled=" KHÔNG có bản cũ để hoàn tác SBC (lần đầu): SBC có thể đang không có cert. CẦN KIỂM TRA TAY SBC (xem: cert-deploy.sh baseline)."; SBC_NEEDS_MANUAL=1
    fi
    SBC_REASON="sau AddCert, cổng SBC chưa phục vụ serial $want ($rep). Phản hồi AddCert: ${first_resp:-không có}.$rolled"
    return 1
}

cmd_apply() {
    local label="$1" force="${2:-}" want pbx sbc n=0 ATT status rep dl m err manual touched pre_pbx pre_sbc now_pbx now_sbc trylabel tail="" final next
    want=$(cat "$STAGE/serial" 2>/dev/null) || { echo "Chưa có cert nào được chuẩn bị"; return 2; }
    # Chỉ thay khi có cert chờ áp dụng (dấu pending). Muốn ép: cert-deploy.sh now --force
    if [ ! -f "$PENDING" ] && [ "$force" != "--force" ]; then
        echo "Không có cert chờ áp dụng: không thay gì (nếu cần ép: cert-deploy.sh now --force)"; return 2
    fi
    if pbx_ok "$want" && sbc_ok "$want"; then
        # Mọi cổng đã phục vụ đúng cert: xoá dấu chờ (nếu còn) và bộ đếm
        [ -f "$PENDING" ] && log "Cổng đã phục vụ đúng cert $want: xoá dấu CHỜ ÁP DỤNG"
        rm -f "$PENDING" "$STATE_DIR"/attempts-*; echo "Không có gì cần áp dụng"; return 2
    fi
    # Hoãn việc thay cert (tuỳ chọn): lượt tự động chỉ thay khi cert đang dùng còn <= DEPLOY_WHEN_DAYS_LEFT ngày; lệnh now thì bỏ qua
    if [ "$label" == "TỰ ĐỘNG" ] && [ -n "${DEPLOY_WHEN_DAYS_LEFT:-}" ]; then
        dl=$(min_days_all)
        if [ -n "$dl" ] && [ "$dl" -gt "$DEPLOY_WHEN_DAYS_LEFT" ]; then
            m="$STATE_DIR/deploy-wait-logged-$(date +%F)"
            if [ ! -f "$m" ]; then
                log "Chưa đến hạn thay: cert đang dùng còn $dl ngày, ngưỡng DEPLOY_WHEN_DAYS_LEFT=$DEPLOY_WHEN_DAYS_LEFT ngày. Giữ cert $want ở trạng thái chờ"
                find "$STATE_DIR" -maxdepth 1 -name 'deploy-wait-logged-*' -delete 2>/dev/null; : > "$m"
            fi
            return 0
        fi
    fi
    ATT="$STATE_DIR/attempts-$want"
    if [ "$label" == "TỰ ĐỘNG" ]; then
        n=$(cat "$ATT" 2>/dev/null || echo 0)
        if [ "$n" -ge "$MAX_AUTO_ATTEMPTS" ]; then
            if [ ! -f "$ATT.alerted" ]; then
                notify_telegram "$(printf '<b>CẢNH BÁO: dừng áp dụng tự động</b>\nDomain: %s\nSerial: %s\nĐã thử %s lần không thành công; PBX và SBC vẫn ở cert cũ (hoặc cần kiểm tra tay, xem tin [2/2] trước đó). Kiểm tra log %s rồi chạy tay: sudo cert-deploy.sh now' "$DOMAIN" "$want" "$n" "$LOG")"
                touch "$ATT.alerted"
            fi
            return 0
        fi
        echo $((n + 1)) > "$ATT"
    fi
    if [ "$label" == "TỰ ĐỘNG" ]; then trylabel="Lần thử tự động: $((n + 1))/$MAX_AUTO_ATTEMPTS"; else trylabel="Chạy tay (không tính vào giới hạn lần thử)"; fi

    pre_pbx=$(pbx_report); pre_sbc=$(sbc_report)
    pbx="đã đúng từ trước"; sbc="đã đúng từ trước"; err=0; manual=0; touched=0; PBX_CHANGED=0; PBX_OLD_SERIAL=""; SBC_TOUCHED=0; SBC_NEEDS_MANUAL=0; PBX_NEEDS_MANUAL=0
    if ! pbx_ok "$want"; then
        log "PBX: thay cert (${PBX_SSH:-tại chỗ}) rồi restart"
        if pbx_replace "$want"; then pbx="THÀNH CÔNG"
        else pbx="THẤT BẠI ($PBX_REASON)"; log "PBX: $PBX_REASON"; err=1; [ "$PBX_NEEDS_MANUAL" -eq 1 ] && manual=1; fi
        [ "$PBX_CHANGED" -eq 1 ] && touched=1
    fi
    if [ "$err" -eq 1 ]; then
        # Hoàn tác cả hai: PBX lỗi thì không đụng SBC, để hai bên cùng ở cert cũ
        sbc="BỎ QUA (PBX lỗi: giữ SBC ở cert cũ để hai bên đồng nhất)"
        log "SBC: bỏ qua vì PBX lỗi"
    elif ! sbc_ok "$want"; then
        log "SBC: thay cert qua API"
        if apply_sbc "$want"; then sbc="THÀNH CÔNG"
        else
            sbc="THẤT BẠI (${SBC_REASON:-không rõ lý do})"; log "SBC: ${SBC_REASON:-không rõ lý do}"; err=1
            [ "$SBC_NEEDS_MANUAL" -eq 1 ] && manual=1
            [ "$SBC_TOUCHED" -eq 1 ] && touched=1
            if [ "$PBX_CHANGED" -eq 1 ]; then
                # SBC lỗi: đưa PBX về cert cũ để hai bên đồng nhất
                log "PBX: hoàn tác vì SBC lỗi"
                if pbx_undo; then pbx="ĐÃ HOÀN TÁC vì SBC lỗi:$PBX_UNDO_NOTE"
                else pbx="HOÀN TÁC LỖI sau khi SBC lỗi:$PBX_UNDO_NOTE"; manual=1; fi
            fi
        fi
    fi
    now_pbx=$(pbx_report); now_sbc=$(sbc_report)

    status="THÀNH CÔNG"
    if [ "$err" -eq 1 ]; then
        status="CÓ LỖI"
        if   [ "$manual" -eq 1 ];  then final="CẦN KIỂM TRA TAY: có bên không hoàn tác được về cert cũ (xem các dòng PBX và SBC ở trên)."
        elif [ "$touched" -eq 1 ]; then final="ĐÃ HOÀN TÁC: PBX và SBC đều phục vụ cert cũ."
        else final="KHÔNG THAY ĐỔI GÌ: PBX và SBC vẫn phục vụ cert cũ."; fi
        if [ "$label" == "TỰ ĐỘNG" ]; then
            if [ "$manual" -eq 1 ]; then
                next="Hệ thống DỪNG tự thử lại vì cần người kiểm tra. Xử lý xong thì chạy: sudo cert-deploy.sh now"
                echo "$MAX_AUTO_ATTEMPTS" > "$ATT"; touch "$ATT.alerted"
            elif [ $((n + 1)) -lt "$MAX_AUTO_ATTEMPTS" ]; then
                next="Sẽ tự thử lại (còn $((MAX_AUTO_ATTEMPTS - n - 1)) lượt) sau khoảng 15 phút nếu còn trong khung giờ ${WINDOW_START}h-${WINDOW_END}h, nếu không thì vào đêm sau."
            else
                next="Đã dùng hết $MAX_AUTO_ATTEMPTS lượt tự động, hệ thống dừng. Xử lý nguyên nhân rồi chạy: sudo cert-deploy.sh now"
            fi
        else
            next="Cert vẫn CHỜ ÁP DỤNG. Xử lý nguyên nhân rồi chạy lại: sudo cert-deploy.sh now"
        fi
        tail=$(printf '\nKết quả: %s\nTiếp theo: %s' "$(printf '%s' "$final" | esc)" "$(printf '%s' "$next" | esc)")
    fi
    notify_telegram "$(printf '<b>[2/2] Thay cert cho PortSIP (%s): %s</b>\nDomain: %s\nSerial mới: %s\nTrước khi thay: PBX %s | SBC %s\nPBX: %s\nSBC: %s\n%s\nHiện tại: PBX %s | SBC %s%s' \
        "$label" "$status" "$DOMAIN" "$want" "$(printf '%s' "$pre_pbx" | esc)" "$(printf '%s' "$pre_sbc" | esc)" \
        "$(printf '%s' "$pbx" | esc)" "$(printf '%s' "$sbc" | esc)" "$trylabel" "$(printf '%s' "$now_pbx" | esc)" "$(printf '%s' "$now_sbc" | esc)" "$tail")"
    if [ "$err" -eq 1 ]; then
        [ -f "$PENDING" ] && echo "last_failed=$(date '+%F %T')" >> "$PENDING"
        return 1
    fi
    keep_applied      # cert vừa áp dụng thành công thành mốc hoàn tác cho lần sau (kể cả khi SBC vốn đã đúng và chỉ PBX đổi)
    rm -f "$PENDING" "$STATE_DIR"/attempts-*
    echo "$(date '+%F %T') serial=$want" > "$STATE_DIR/applied-at"
    log "Đã áp dụng cert $want, xoá dấu CHỜ ÁP DỤNG"
    return 0
}

cmd_status() {
    local p
    if [ -f "$PENDING" ]; then
        echo "Trạng thái: ĐANG CHỜ ÁP DỤNG"; sed 's/^/            /' "$PENDING"
    else
        echo "Trạng thái: không có cert chờ ($(cat "$STATE_DIR/applied-at" 2>/dev/null | sed 's/^/áp dụng lần cuối /' || true))"
    fi
    if [ -n "${DEPLOY_WHEN_DAYS_LEFT:-}" ]; then
        echo "Hoãn thay : bật, lượt tự động chỉ thay khi cert đang dùng còn <= $DEPLOY_WHEN_DAYS_LEFT ngày (hiện còn $(min_days_all) ngày)"
    fi
    echo "Mong muốn : $(cat "$STAGE/serial" 2>/dev/null || echo 'chưa có')"
    echo "PBX thay  : $([ -n "${PBX_SSH:-}" ] && echo "qua SSH tới $PBX_SSH" || echo "tại chỗ") | quy tắc: chỉ thay khi có cert chờ; một bên lỗi thì hoàn tác cả hai | tối đa $MAX_AUTO_ATTEMPTS lần tự động"
    echo "Mốc hoàn tác SBC: $(cat "$APPLIED/serial" 2>/dev/null || echo 'chưa có (chạy cert-deploy.sh baseline trước lần thay đầu)')"
    [ -n "${PBX_PORTS:-}" ] || echo "CẢNH BÁO: PBX_PORTS rỗng: PBX bị coi là luôn đúng và sẽ không bao giờ được thay"
    for p in $PBX_PORTS; do echo "PBX  :$p -> $(SNI="$PBX_SNI_EFF" live_serial "$p")"; done
    for p in $SBC_PORTS; do echo "SBC  :$p -> $(SNI="$SBC_SNI_EFF" live_serial "$p")"; done
}

cmd_stuck() {
    local want h m dl
    want=$(cat "$STAGE/serial" 2>/dev/null) || return 0
    if [ ! -f "$PENDING" ]; then
        rm -f "$STATE_DIR"/stuck-alerted-*
        # Không có cert chờ nên hệ thống KHÔNG tự thay; chỉ báo khi cổng đang phục vụ cert khác cert đã chuẩn bị (ví dụ SBC quay về cert cũ)
        if pbx_ok "$want" && sbc_ok "$want"; then rm -f "$STATE_DIR"/drift-alerted-*; return 0; fi
        m="$STATE_DIR/drift-alerted-$want"
        if [ ! -f "$m" ]; then
            notify_telegram "$(printf '<b>CẢNH BÁO: cổng không phục vụ đúng cert đã chuẩn bị (không có cert chờ)</b>\nDomain: %s\nSerial đã chuẩn bị: %s\nPBX: %s\nSBC: %s\nHệ thống KHÔNG tự thay vì không có cert chờ. Nếu cần thay: sudo cert-deploy.sh now --force' "$DOMAIN" "$want" "$(pbx_report | esc)" "$(sbc_report | esc)")"
            touch "$m"
        fi
        return 0
    fi
    if pbx_ok "$want" && sbc_ok "$want"; then rm -f "$PENDING" "$STATE_DIR"/stuck-alerted-*; return 0; fi
    if [ -n "${DEPLOY_WHEN_DAYS_LEFT:-}" ]; then
        dl=$(min_days_all)
        [ -n "$dl" ] && [ "$dl" -ge "$DEPLOY_WHEN_DAYS_LEFT" ] && return 0   # đang chờ theo thiết kế, chưa tới đêm thay
    fi
    h=$(( ($(date +%s) - $(stat -c %Y "$PENDING")) / 3600 ))
    m="$STATE_DIR/stuck-alerted-$want"
    if [ "$h" -ge "${STUCK_HOURS:-20}" ] && [ ! -f "$m" ]; then
        notify_telegram "$(printf '<b>CẢNH BÁO: cert chưa được áp dụng sau %s giờ</b>\nDomain: %s\nSerial mong muốn: %s\nXem: sudo cert-deploy.sh status' "$h" "$DOMAIN" "$want")"
        touch "$m"
    fi
    return 0
}

# Nhắc cert đang dùng sắp hết hạn: mỗi mốc chỉ báo một lần, hết báo khi đã thay cert mới (số ngày vượt mốc lớn nhất).
# Cần thiết khi cert dán tay (không có Caddy hay lego tự gia hạn), và là lớp an toàn thêm khi dùng Caddy.
cmd_expiry() {
    local dl th hit="" ths src
    dl=$(min_days_all); [ -n "$dl" ] || return 0
    ths=$(printf '%s\n' ${EXPIRY_ALERT_DAYS:-30 14 7 3 1} | sort -n)
    for th in $ths; do [ "$dl" -le "$th" ] && { hit=$th; break; }; done
    if [ -z "$hit" ]; then rm -f "$STATE_DIR"/expiry-alerted-*; return 0; fi
    [ -f "$STATE_DIR/expiry-alerted-$hit" ] && return 0
    if [ -f "$PENDING" ]; then src="Đã có cert mới chờ áp dụng: chạy sudo cert-deploy.sh now hoặc đợi khung giờ."
    else src="Chưa có cert mới. Nguồn cert: ${CERT_SOURCE_NAME:-Caddy}; nếu dán tay thì chạy sudo paste-cert.sh."; fi
    notify_telegram "$(printf '<b>CẢNH BÁO: cert đang dùng sắp hết hạn</b>\nDomain: %s\nCòn %s ngày (mốc cảnh báo %s ngày)\n%s' "$DOMAIN" "$dl" "$hit" "$src")"
    for th in $ths; do [ "$th" -ge "$hit" ] && : > "$STATE_DIR/expiry-alerted-$th"; done
    return 0
}

# Ghi cặp cert ĐANG CHẠY làm mốc hoàn tác cho SBC. Cần cho lần thay đầu tiên, khi chưa có bản "applied" nào:
# nếu không, SBC lỗi sau DeleteCert thì không có gì để khôi phục. Cert phải khớp khoá; chuỗi được chuẩn hoá như khi chuẩn bị.
cmd_baseline() {
    local crt="${1:-}" key="${2:-}" ser N="$STATE_DIR/applied.new"
    if [ ! -r "$crt" ] || [ ! -r "$key" ]; then echo "dùng: cert-deploy.sh baseline <cert-đang-chạy> <khoá-đang-chạy>"; return 1; fi
    openssl x509 -noout -in "$crt" 2>/dev/null || { echo "LỖI: cert không đọc được"; return 1; }
    [ "$(openssl x509 -noout -pubkey -in "$crt" | sha256sum)" == "$(openssl pkey -pubout -in "$key" 2>/dev/null | sha256sum)" ] || { echo "LỖI: khoá không khớp cert"; return 1; }
    ser=$(openssl x509 -noout -serial -in "$crt" | cut -d= -f2)
    rm -rf "$N"; mkdir -p "$N" || { echo "LỖI: không tạo được $N"; return 1; }
    normalize_chain "$crt" "$N/chain.pem" && cp "$key" "$N/key.raw.pem" && openssl pkey -in "$key" -out "$N/key.pem" 2>/dev/null && echo "$ser" > "$N/serial" \
        || { rm -rf "$N"; echo "LỖI: không ghi được mốc hoàn tác"; return 1; }
    rm -rf "$APPLIED"; mv "$N" "$APPLIED"
    log "Đã ghi mốc hoàn tác SBC: cert serial=$ser từ $crt"
    echo "Đã ghi mốc hoàn tác cho SBC: cert serial $ser. Nếu lần thay tới SBC lỗi, hệ thống sẽ khôi phục cert này."
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        status) cmd_status; return ;;
        baseline) shift; cmd_baseline "${1:-}" "${2:-}"; return ;;
        version) cat "${VERSION_FILE:-/usr/local/share/caddy-cert-sync/VERSION}" 2>/dev/null || echo "không rõ (chưa cài bằng install.sh hoặc gói deb)"; return ;;
        stage|apply|now|stuck|expiry) ;;
        *) echo "dùng: cert-deploy.sh stage | apply | now [--force] | status | stuck | expiry | baseline CRT KEY | version"; return 1 ;;
    esac
    # Khoá chống chạy chồng (watcher, timer và lệnh tay có thể trùng giờ):
    # timer bỏ qua lượt nếu đang bận; stage và now đợi tối đa 10 phút.
    exec 9>"$STATE_DIR/.lock"
    case "$cmd" in
        apply|stuck|expiry) flock -n 9 || { log "Đang có một lần chạy khác, bỏ qua lượt $cmd"; return 0; } ;;
        *)           flock -w 600 9 || { log "Chờ khoá quá 10 phút, bỏ lượt $cmd"; return 1; } ;;
    esac
    case "$cmd" in
        stage) cmd_stage ;;
        apply) cmd_stage noapply; in_maintenance_window || return 0; cmd_apply "TỰ ĐỘNG"; return 0 ;;
        now)   cmd_stage noapply; cmd_apply "THỦ CÔNG" "${2:-}" ;;
        stuck) cmd_stuck ;;
        expiry) cmd_expiry ;;
    esac
}
if [ "${BASH_SOURCE[0]}" == "$0" ]; then main "$@"; exit $?; fi
