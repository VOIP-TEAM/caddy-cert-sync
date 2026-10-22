#!/bin/bash
# paste-cert.sh — dán cert và khoá riêng vào server này, kiểm tra kỹ, rồi đặt vào thư mục cert nguồn để hệ thống chuẩn bị và thay.
#   sudo paste-cert.sh                                dán vào terminal (gõ END ở dòng mới sau mỗi phần)
#   sudo paste-cert.sh --crt cert.pem --key khoa.pem  lấy từ file đã chép sẵn lên server
# Tuỳ chọn: --yes (bỏ hỏi xác nhận), --no-stage (không chạy stage), --allow-domain-mismatch
# Cert đặt ở $CADDY_CERT_BASE/certificates/manual/<DOMAIN>.crt và .key (quyền 600). Bản cũ được sao lưu trước khi thay.
set -uo pipefail
CFG_DIR="${CFG_DIR:-/etc/caddy-cert-sync}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
# shellcheck disable=SC1091
source "$CFG_DIR/config.conf" || { echo "Không đọc được $CFG_DIR/config.conf"; exit 2; }
CRT_IN=""; KEY_IN=""; YES=0; NOSTAGE=0; ALLOWMM=0
while [ $# -gt 0 ]; do
    case "$1" in
        --crt) [ $# -ge 2 ] || { echo "thiếu đường dẫn sau --crt"; exit 2; }; CRT_IN="$2"; shift 2 ;;
        --key) [ $# -ge 2 ] || { echo "thiếu đường dẫn sau --key"; exit 2; }; KEY_IN="$2"; shift 2 ;;
        --yes) YES=1; shift ;;
        --no-stage) NOSTAGE=1; shift ;;
        --allow-domain-mismatch) ALLOWMM=1; shift ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) echo "tuỳ chọn không hợp lệ: $1"; exit 2 ;;
    esac
done
umask 077
W=$(mktemp -d)
trap 'rm -rf "$W"; if [ -t 0 ]; then stty echo 2>/dev/null; fi' EXIT
die()  { echo "LỖI: $*" >&2; exit 1; }
warn() { echo "CẢNH BÁO: $*"; }

read_block() {   # $1 nhãn, $2 file đích, $3 = 1 nếu cần ẩn khi dán (khoá riêng)
    local label="$1" out="$2" hide="${3:-0}" line
    if [ -t 0 ]; then echo "Dán $label rồi gõ END ở dòng mới và nhấn Enter:"; [ "$hide" = 1 ] && stty -echo; fi
    : > "$out"
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ "$(printf '%s' "$line" | tr -d '[:space:]')" == "END" ] && break
        printf '%s\n' "$line" >> "$out"
    done
    if [ -t 0 ] && [ "$hide" = 1 ]; then stty echo; echo; fi
    [ -s "$out" ]
}
clean() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | tr -d '\r' | grep -v '^$' > "$1.clean"; mv "$1.clean" "$1"; }

# --- 1. lấy nội dung ---
if [ -n "$CRT_IN" ] || [ -n "$KEY_IN" ]; then
    [ -n "$CRT_IN" ] && [ -n "$KEY_IN" ] || die "phải đưa cả --crt và --key"
    [ -r "$CRT_IN" ] || die "không đọc được $CRT_IN"; [ -r "$KEY_IN" ] || die "không đọc được $KEY_IN"
    cp "$CRT_IN" "$W/in.crt"; cp "$KEY_IN" "$W/in.key"
else
    read_block "CHUỖI CERT (cert của domain đứng đầu, rồi cert trung gian)" "$W/in.crt" 0 || die "chưa nhận được nội dung cert"
    read_block "KHOÁ RIÊNG (sẽ không hiện trên màn hình)" "$W/in.key" 1 || die "chưa nhận được nội dung khoá"
fi
clean "$W/in.crt"; clean "$W/in.key"

# --- 2. kiểm tra ---
awk -v d="$W" '/-----BEGIN CERTIFICATE-----/{n++} n>0{print > (d "/c" n ".pem")}' "$W/in.crt"
N=$(find "$W" -maxdepth 1 -name 'c[0-9]*.pem' | wc -l)
[ "$N" -ge 1 ] || die "không thấy khối -----BEGIN CERTIFICATE----- nào. Kiểm tra đã dán đủ từ dòng BEGIN tới END, và mỗi dòng đứng riêng"
for i in $(seq 1 "$N"); do
    openssl x509 -noout -in "$W/c$i.pem" 2>/dev/null || die "cert thứ $i trong chuỗi không đọc được (dán thiếu hoặc dính dòng)"
done
grep -q "ENCRYPTED" "$W/in.key" && die "khoá riêng có mật khẩu. Gỡ mật khẩu trước: openssl pkey -in khoa-co-mat-khau.key -out khoa.key"
openssl pkey -in "$W/in.key" -noout 2>/dev/null || die "khoá riêng không đọc được (dán thiếu hoặc sai định dạng)"
[ "$(openssl x509 -noout -pubkey -in "$W/c1.pem" | sha256sum)" == "$(openssl pkey -pubout -in "$W/in.key" | sha256sum)" ] \
    || die "khoá riêng KHÔNG khớp với cert đứng đầu chuỗi"

LEAF="$W/c1.pem"
SAN=$(openssl x509 -noout -ext subjectAltName -in "$LEAF" 2>/dev/null | grep -o 'DNS:[^,[:space:]]*' | sed 's/^DNS://')
CN=$(openssl x509 -noout -subject -nameopt multiline -in "$LEAF" | sed -n 's/^ *commonName *= *//p')
covers() {   # $1 = file cert, $2 = domain
    local names n d="$2"
    names="$(openssl x509 -noout -ext subjectAltName -in "$1" 2>/dev/null | grep -o 'DNS:[^,[:space:]]*' | sed 's/^DNS://') $(openssl x509 -noout -subject -nameopt multiline -in "$1" | sed -n 's/^ *commonName *= *//p')"
    for n in $names; do
        [ "$n" == "$d" ] && return 0
        case "$n" in \*.*) [ "$d" != "${d#*.}" ] && [ "${d#*.}" == "${n#*.}" ] && return 0 ;; esac
    done; return 1
}
for dom in "$DOMAIN" "${SBC_TLS_DOMAIN:-$DOMAIN}"; do
    covers "$LEAF" "$dom" && continue
    for i in $(seq 2 "$N"); do
        covers "$W/c$i.pem" "$dom" && die "cert của $dom nằm ở vị trí $i, nhưng phải đứng ĐẦU chuỗi (rồi mới tới cert trung gian). Dán lại theo đúng thứ tự"
    done
    if [ "$ALLOWMM" -eq 1 ]; then warn "cert không phủ $dom (tiếp tục vì có --allow-domain-mismatch)"
    else die "cert không phủ domain $dom (SAN: ${SAN:-không có}; CN: ${CN:-không có}). Nếu chủ ý, thêm --allow-domain-mismatch"; fi
done
ISSUER=$(openssl x509 -noout -issuer -in "$LEAF")
case "${ISSUER,,}" in *staging*) die "đây là cert staging, không dùng được với client thật ($ISSUER)" ;; esac
openssl x509 -checkend 0 -noout -in "$LEAF" >/dev/null || die "cert đã HẾT HẠN"
END=$(openssl x509 -noout -enddate -in "$LEAF" | cut -d= -f2)
DAYS=$(( ($(date -d "$END" +%s) - $(date +%s)) / 86400 ))
[ "$DAYS" -lt 14 ] && warn "cert chỉ còn $DAYS ngày"
if [ "$N" -ge 2 ]; then
    [ "$(openssl x509 -noout -issuer_hash -in "$LEAF")" == "$(openssl x509 -noout -subject_hash -in "$W/c2.pem")" ] \
        || warn "cert thứ hai không phải cert phát hành ra cert đầu (chuỗi có thể sai thứ tự hoặc thiếu cert)"
else warn "chuỗi chỉ có 1 cert (thiếu cert trung gian); nhiều client sẽ không tin"; fi

echo "----- Tóm tắt cert sẽ đặt -----"
echo "  $(openssl x509 -noout -serial -in "$LEAF")"
echo "  $(openssl x509 -noout -subject -in "$LEAF")"
echo "  SAN: ${SAN:-không có}"
echo "  $ISSUER"
echo "  hết hạn: $END (còn $DAYS ngày) | số cert trong chuỗi: $N"
if [ "$YES" -ne 1 ]; then
    printf 'Đặt cert này vào %s? [y/N] ' "$CADDY_CERT_BASE/certificates/manual"
    read -r ans || ans=""
    case "$ans" in y|Y|yes) ;; *) echo "Đã huỷ, không thay đổi gì."; exit 1 ;; esac
fi

# --- 3. đặt cert (khoá trước, cert sau cùng để watcher luôn thấy một cặp đầy đủ) ---
DEST="$CADDY_CERT_BASE/certificates/manual"
install -d -m 700 "$DEST"
if [ -f "$DEST/$DOMAIN.crt" ] || [ -f "$DEST/$DOMAIN.key" ]; then
    BK="$STATE_DIR/paste-backup/$(date +%Y%m%d-%H%M%S)"; install -d -m 700 "$BK"
    cp -p "$DEST/$DOMAIN.crt" "$DEST/$DOMAIN.key" "$BK/" 2>/dev/null; echo "Đã sao lưu bản cũ vào $BK"
fi
install -m 600 "$W/in.key" "$DEST/.$DOMAIN.key.tmp"; install -m 600 "$W/in.crt" "$DEST/.$DOMAIN.crt.tmp"
mv "$DEST/.$DOMAIN.key.tmp" "$DEST/$DOMAIN.key"; mv "$DEST/.$DOMAIN.crt.tmp" "$DEST/$DOMAIN.crt"
echo "Đã đặt $DEST/$DOMAIN.crt và .key (quyền 600)."

if [ "$NOSTAGE" -eq 1 ]; then
    echo "Chưa chạy stage (--no-stage). Chạy: sudo cert-deploy.sh stage"
else
    echo "Chạy stage (nếu đang trong khung giờ ${WINDOW_START:-22}h-${WINDOW_END:-5}h, stage sẽ áp dụng ngay)..."
    "$BIN_DIR/cert-deploy.sh" stage
fi
echo "Xem trạng thái: sudo cert-deploy.sh status   |   áp dụng ngay: sudo cert-deploy.sh now"
