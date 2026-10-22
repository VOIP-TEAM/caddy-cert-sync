#!/bin/bash
# Gọi API của SBC. Mật khẩu đi qua biến môi trường, token đi qua file header (không lộ trên dòng lệnh).
SBC_TOKEN=""

# Đăng nhập: lấy token từ phản hồi AuthUser theo SBC_TOKEN_JQ. Thất bại thì SBC_LOGIN_INFO ghi mã HTTP, phản hồi
# (giá trị dài hơn 16 ký tự bị ẩn nên không lộ token) và biểu thức jq của chuỗi trông giống token.
# Biểu thức luôn viết dạng .["khoá"] vì khoá có dấu gạch ngang (như access-token) sẽ bị jq hiểu thành phép trừ nếu viết .khoá
sbc_login() {
    local b resp code masked cands n jqpath
    b=$(mktemp); resp=$(mktemp); SBC_LOGIN_INFO=""
    jqpath="${SBC_TOKEN_JQ:-}"; [ -n "$jqpath" ] || jqpath='.["access-token"]'
    U="$SBC_USER" P="$SBC_PASS" jq -n '{user_name:env.U,password:env.P}' > "$b"
    code=$(curl -sk -m 20 -X POST -H 'Content-Type: application/json' -d @"$b" -o "$resp" -w '%{http_code}' "$SBC_API_BASE/AuthUser")
    rm -f "$b"
    SBC_TOKEN=$(jq -r "$jqpath // empty" "$resp" 2>/dev/null)
    if [ -z "$SBC_TOKEN" ]; then
        masked=$(jq -c 'walk(if type=="string" and length>16 then "<ẩn \(length) ký tự>" else . end)' "$resp" 2>/dev/null || head -c 120 "$resp" | tr -d '\n')
        SBC_LOGIN_INFO="HTTP ${code:-000}, phản hồi: ${masked:-rỗng}"
        cands=$(jq -c '[paths(scalars) as $p | select((getpath($p)|type)=="string" and (getpath($p)|test("^[0-9a-f]{32}$"))) | "." + ($p|map("[\(tojson)]")|join(""))]' "$resp" 2>/dev/null)
        n=$(printf '%s' "${cands:-[]}" | jq 'length' 2>/dev/null)
        if   [ "${n:-0}" -eq 1 ]; then SBC_LOGIN_INFO="$SBC_LOGIN_INFO; chuỗi giống token nằm ở $(printf '%s' "$cands" | jq -r '.[0]') (thử SBC_TOKEN_JQ='$(printf '%s' "$cands" | jq -r '.[0]')')"
        elif [ "${n:-0}" -gt 1 ]; then SBC_LOGIN_INFO="$SBC_LOGIN_INFO; có nhiều chuỗi giống token: $(printf '%s' "$cands" | jq -r 'join(", ")')"
        fi
    fi
    rm -f "$resp"
    [ -n "$SBC_TOKEN" ]
}

# sbc_call <endpoint> [file JSON]  (có file thì POST)
sbc_call() {
    local h rc ct=()
    h=$(mktemp)
    printf 'access-token: %s\n' "$SBC_TOKEN" > "$h"
    [ -n "${SBC_CONTENT_TYPE-application/json}" ] && ct=(-H "Content-Type: ${SBC_CONTENT_TYPE-application/json}")
    if [ -n "${2:-}" ]; then
        curl -sk -m 90 -X POST "${ct[@]}" -H @"$h" -d @"$2" "$SBC_API_BASE/$1"
    else
        curl -sk -m 30 -H @"$h" "$SBC_API_BASE/$1"
    fi
    rc=$?
    rm -f "$h"
    return $rc
}

# sbc_add <thư mục có chain.pem và key.pem>
sbc_add() {
    local b
    b=$(mktemp)
    jq -n --arg d "$SBC_TLS_DOMAIN" --argjson w "${SBC_WEB_DOMAIN:-true}" \
        --rawfile c "$1/chain.pem" --rawfile k "$1/key.pem" \
        '{description:$d,tls_domain:$d,for_sbc_web_domain:$w,cert:$c,private_key:$k}' > "$b"
    SBC_LAST_RESP=$(sbc_call AddCert "$b" | head -c 200)
    log "SBC AddCert: $SBC_LAST_RESP"
    rm -f "$b"
}

sbc_delete() {
    local b
    b=$(mktemp)
    jq -n --arg k "pcert_key:$SBC_TLS_DOMAIN" '{key:$k}' > "$b"
    log "SBC DeleteCert: $(sbc_call DeleteCert "$b" | head -c 200)"
    rm -f "$b"
}
