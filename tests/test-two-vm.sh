#!/bin/bash
# tests/test-two-vm.sh — kiểm thử paste-cert.sh và health-check.sh khi SBC ở VM khác (giả lập bằng 127.0.0.2). Không cần PortSIP.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d /tmp/twovm-test.XXXXXX)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
ok=0; bad=0
check() { if eval "$2"; then echo "  OK   $1"; ok=$((ok+1)); else echo "  FAIL $1"; bad=$((bad+1)); fi; }
mkdir -p "$T/cfg" "$T/cfgw" "$T/bin" "$T/state" "$T/c"
cd "$T/c" || exit 1
mk() { openssl ecparam -name prime256v1 -genkey -noout -out "$1.key" 2>/dev/null; }
mk root; openssl req -x509 -new -key root.key -subj "/CN=Test Root" -days 30 -out root.crt 2>/dev/null
mk int; openssl req -new -key int.key -subj "/CN=Test Int" -out int.csr 2>/dev/null
openssl x509 -req -in int.csr -CA root.crt -CAkey root.key -set_serial 0x9 -days 30 -out int.crt -extfile <(echo "basicConstraints=CA:TRUE") 2>/dev/null
leaf() { mk "$1"; openssl req -new -key "$1.key" -subj "/CN=$2" -out "$1.csr" 2>/dev/null
         openssl x509 -req -in "$1.csr" -CA int.crt -CAkey int.key -set_serial "$3" -days "${5:-30}" -out "$1.crt" -extfile <(echo "subjectAltName=$4") 2>/dev/null; }
leaf good  pbx.test  0x101 "DNS:pbx.test,DNS:sbc.test"
leaf good2 pbx.test  0x102 "DNS:pbx.test,DNS:sbc.test"
leaf other other.test 0x103 "DNS:other.test"
leaf wild  "*.test2" 0x104 "DNS:*.test2"
leaf dead  pbx.test  0x105 "DNS:pbx.test,DNS:sbc.test" 0
cat good.crt int.crt > good.chain; cat good2.crt int.crt > good2.chain; cat other.crt int.crt > other.chain
cat wild.crt int.crt > wild.chain; cat dead.crt int.crt > dead.chain; cat int.crt good.crt > wrong-order.chain
openssl pkey -in good.key -aes256 -passout pass:x -out good.enc.key 2>/dev/null
sleep 2   # để cert "dead" (days 0) thật sự hết hạn

cat > "$T/cfg/config.conf" << C
DOMAIN="pbx.test"
SBC_TLS_DOMAIN="sbc.test"
CADDY_CERT_BASE="$T/drop"
STATE_DIR="$T/state"
LOG="$T/log"
WINDOW_START=22
WINDOW_END=5
C
sed 's/pbx.test/pbx.test2/; s/sbc.test/sbc.test2/' "$T/cfg/config.conf" > "$T/cfgw/config.conf"
printf '#!/bin/bash\necho "$1" >> "$CALLS"\n' > "$T/bin/cert-deploy.sh"; chmod +x "$T/bin/cert-deploy.sh"
export CALLS="$T/calls" BIN_DIR="$T/bin"
D="$T/drop/certificates/manual"
paste() {   # $1 = file chuỗi cert, $2 = file khoá, $3 = trả lời xác nhận, còn lại = tuỳ chọn; CFG_DIR lấy từ môi trường
    local c="$1" k="$2" a="$3"; shift 3
    { cat "$c"; echo END; cat "$k"; echo END; echo "$a"; } | CFG_DIR="${CFG_DIR:-$T/cfg}" bash "$ROOT/bin/paste-cert.sh" "$@" 2>&1
}
fresh() { rm -rf "$T/drop" "$T/state/paste-backup" "$CALLS"; }
export CFG_DIR="$T/cfg"

echo "== P1 dán hợp lệ"
fresh; out=$(paste good.chain good.key y); rc=$?
check "chấp nhận, thoát mã 0" '[ $rc = 0 ]'
check "đặt cert và khoá đúng chỗ, quyền 600" '[ -s "$D/pbx.test.crt" ] && [ -s "$D/pbx.test.key" ] && [ "$(stat -c %a "$D/pbx.test.crt")" = 600 ] && [ "$(stat -c %a "$D/pbx.test.key")" = 600 ]'
check "tóm tắt có serial và số cert trong chuỗi" 'echo "$out" | grep -q "serial=0101" && echo "$out" | grep -q "số cert trong chuỗi: 2"'
check "gọi cert-deploy.sh stage đúng một lần" '[ "$(grep -c "^stage$" "$CALLS")" = 1 ]'
check "khoá không in ra màn hình" '! echo "$out" | grep -q "PRIVATE KEY"'
echo "== P2 khoá không khớp"; fresh; out=$(paste good.chain good2.key y); rc=$?
check "từ chối, không tạo file" '[ $rc != 0 ] && echo "$out" | grep -q "KHÔNG khớp" && [ ! -e "$D/pbx.test.crt" ]'
echo "== P3 khoá có mật khẩu"; fresh; out=$(paste good.chain good.enc.key y); rc=$?
check "từ chối và hướng dẫn gỡ mật khẩu" '[ $rc != 0 ] && echo "$out" | grep -q "mật khẩu" && [ ! -e "$D/pbx.test.crt" ]'
echo "== P4 cert không phủ domain"; fresh; out=$(paste other.chain good.key y); rc=$?
check "khoá của cert khác bị từ chối" '[ $rc != 0 ]'
fresh; out=$(paste other.chain other.key y); rc=$?
check "cert không phủ domain bị từ chối, nói rõ SAN" '[ $rc != 0 ] && echo "$out" | grep -q "không phủ domain pbx.test" && echo "$out" | grep -q "other.test"'
fresh; out=$(paste other.chain other.key y --allow-domain-mismatch); rc=$?
check "có --allow-domain-mismatch thì chấp nhận kèm cảnh báo" '[ $rc = 0 ] && echo "$out" | grep -q "CẢNH BÁO: cert không phủ"'
echo "== P5 wildcard"; fresh; out=$(CFG_DIR="$T/cfgw" paste wild.chain wild.key y); rc=$?
check "*.test2 phủ pbx.test2 và sbc.test2" '[ $rc = 0 ] && [ -s "$T/drop/certificates/manual/pbx.test2.crt" ]'
echo "== P6 hết hạn"; fresh; out=$(paste dead.chain dead.key y); rc=$?
check "cert hết hạn bị từ chối" '[ $rc != 0 ] && echo "$out" | grep -q "HẾT HẠN"'
echo "== P7 lấy từ file"; fresh; out=$(CFG_DIR="$T/cfg" bash "$ROOT/bin/paste-cert.sh" --crt good.chain --key good.key --yes 2>&1); rc=$?
check "--crt --key --yes chạy không cần dán" '[ $rc = 0 ] && [ -s "$D/pbx.test.crt" ]'
echo "== P8 thay cert đã có: sao lưu bản cũ"; out=$(paste good2.chain good2.key y); rc=$?
check "bản cũ được sao lưu" '[ $rc = 0 ] && [ "$(find "$T/state/paste-backup" -name pbx.test.crt | wc -l)" = 1 ]'
check "file hiện tại là bản mới" 'openssl x509 -noout -serial -in "$D/pbx.test.crt" | grep -q "serial=0102"'
check "bản sao lưu là bản cũ" 'openssl x509 -noout -serial -in "$(find "$T/state/paste-backup" -name pbx.test.crt | head -1)" | grep -q "serial=0101"'
echo "== P9 sai thứ tự chuỗi"; fresh; out=$(paste wrong-order.chain good.key y); rc=$?
check "cert trung gian đứng đầu bị từ chối (khoá không khớp cert đầu)" '[ $rc != 0 ]'
echo "== P10 --no-stage"; fresh; out=$(paste good.chain good.key y --no-stage); rc=$?
check "đặt cert nhưng không gọi stage" '[ $rc = 0 ] && [ -s "$D/pbx.test.crt" ] && [ ! -e "$CALLS" ]'
echo "== P11 từ chối ở bước xác nhận"; fresh; out=$(paste good.chain good.key n); rc=$?
check "trả lời n: huỷ, không đặt file" '[ $rc != 0 ] && [ ! -e "$D/pbx.test.crt" ] && echo "$out" | grep -q "Đã huỷ"'
echo "== P12 chuỗi chỉ có 1 cert"; fresh; out=$(paste good.crt good.key y); rc=$?
check "chấp nhận nhưng cảnh báo thiếu cert trung gian" '[ $rc = 0 ] && echo "$out" | grep -q "chỉ có 1 cert"'
echo "== P13 dán dính CRLF và thụt dòng (lỗi hay gặp khi dán qua terminal)"
fresh; sed -e 's/^/    /' -e 's/$/\r/' good.chain > good.mess.chain; sed -e 's/^/  /' -e 's/$/\r/' good.key > good.mess.key
out=$(paste good.mess.chain good.mess.key y); rc=$?
check "chuẩn hoá được và chấp nhận" '[ $rc = 0 ] && openssl x509 -noout -in "$D/pbx.test.crt" 2>/dev/null && ! grep -q $'"'"'\r'"'"' "$D/pbx.test.crt"'
echo "== P14 dán thiếu (cắt mất dòng END của cert)"
fresh; head -n -1 good.chain > good.cut.chain; out=$(paste good.cut.chain good.key y); rc=$?
check "cert dán thiếu bị từ chối, không đặt file" '[ $rc != 0 ] && [ ! -e "$D/pbx.test.crt" ]'

echo "== H health-check khi SBC ở máy khác (127.0.0.2)"
mkdir -p "$T/hc/state/staged" "$T/stubs"
echo 0101 > "$T/hc/state/staged/serial"
printf 'DOMAIN="pbx.test"\nSBC_TLS_DOMAIN="sbc.test"\nCADDY_CERT_BASE="%s/none"\nSTATE_DIR="%s/hc/state"\nLOG="%s/hc/log"\nSBC_PORTS="127.0.0.2:18999 127.0.0.2:18998"\nSBC_DOCKER_CMD=none\n' "$T" "$T" "$T" > "$T/hc/config.conf"
printf '#!/bin/bash\ncase "$1" in ps) printf "portsip.webserver\\n";; inspect) echo "running 0 - 2026-01-01T00:00:00Z";; esac\n' > "$T/stubs/docker"
printf '#!/bin/bash\n[ "$1" == s_client ] && echo "$*" >> "%s/ssl.log"\nexec %s "$@"\n' "$T" "$(command -v openssl)" > "$T/stubs/openssl"
chmod +x "$T/stubs/docker" "$T/stubs/openssl"
openssl s_server -accept 127.0.0.2:18999 -cert good.crt -key good.key -www -quiet >/dev/null 2>&1 &
sleep 1
out=$(PATH="$T/stubs:$PATH" CFG_DIR="$T/hc" SYSTEMD_RUN_DIR="$T/khong" bash "$ROOT/bin/health-check.sh" 2>&1)
check "cổng ở máy khác đo được và đúng cert đã chuẩn bị" 'echo "$out" | grep -q "^\[OK\] .*SBC :127.0.0.2:18999 serial=0101"'
check "PBX_PORTS rỗng bị health-check báo LỖI" 'echo "$out" | grep -q "^\[LỖI\] .*PBX_PORTS rỗng"'
check "cổng ở máy khác không kết nối được bị báo lỗi" 'echo "$out" | grep -q "^\[LỖI\] .*SBC :127.0.0.2:18998 không kết nối được"'
check "SBC_DOCKER_CMD=none: bỏ qua kiểm tra tiến trình SBC, không gọi docker exec" 'echo "$out" | grep -q "SBC ở VM khác" && ! echo "$out" | grep -q "SBC: "'
check "đo SBC bằng SNI của SBC (sbc.test), không phải domain PBX" 'grep -q -- "-connect 127.0.0.2:18999 -servername sbc.test" "$T/ssl.log"'

echo "== I health-check: PBX_SSH đặt nhưng PBX_PORTS thiếu IP (lỗi hay gặp khi tự chỉnh hồ sơ same-vm cho khác VM)"
# Thư mục và cổng RIÊNG, không dùng chung với bài test H phía trên: tránh mọi phụ thuộc
# vào tiến trình hay trạng thái còn sót lại, dù bài test này vốn không cần nối mạng thật
# (kiểm tra chỉ đọc biến cấu hình, chạy trước phần đo cổng của health-check.sh).
mkdir -p "$T/hci1" "$T/hci2" "$T/hci3"
printf 'DOMAIN="pbx.test"\nSBC_TLS_DOMAIN="sbc.test"\nCADDY_CERT_BASE="%s/none"\nSTATE_DIR="%s/hci1/state"\nLOG="%s/hci1/log"\nPBX_PORTS="8887"\nSBC_PORTS="127.0.0.3:1"\nSBC_DOCKER_CMD=none\nPBX_SSH="root@10.106.222.50"\nPBX_SSH_KEY="%s/hci1/none-key"\n' "$T" "$T" "$T" "$T" > "$T/hci1/config.conf"
out=$(PATH="$T/stubs:$PATH" CFG_DIR="$T/hci1" SYSTEMD_RUN_DIR="$T/khong" bash "$ROOT/bin/health-check.sh" 2>&1)
check "PBX_SSH đặt, PBX_PORTS không có IP: báo LỖI và gợi ý đúng IP từ PBX_SSH" 'echo "$out" | grep -q "^\[LỖI\] .*PBX_SSH đã đặt" && echo "$out" | grep -q "10.106.222.50:<cổng>"'

printf 'DOMAIN="pbx.test"\nSBC_TLS_DOMAIN="sbc.test"\nCADDY_CERT_BASE="%s/none"\nSTATE_DIR="%s/hci2/state"\nLOG="%s/hci2/log"\nPBX_PORTS="10.106.222.50:8887"\nSBC_PORTS="127.0.0.3:1"\nSBC_DOCKER_CMD=none\nPBX_SSH="root@10.106.222.50"\nPBX_SSH_KEY="%s/hci2/none-key"\n' "$T" "$T" "$T" "$T" > "$T/hci2/config.conf"
out=$(PATH="$T/stubs:$PATH" CFG_DIR="$T/hci2" SYSTEMD_RUN_DIR="$T/khong" bash "$ROOT/bin/health-check.sh" 2>&1)
check "PBX_SSH đặt, PBX_PORTS đã có IP: không báo lỗi này nữa" '! echo "$out" | grep -q "PBX_SSH đã đặt"'

printf 'DOMAIN="pbx.test"\nCADDY_CERT_BASE="%s/none"\nSTATE_DIR="%s/hci3/state"\nLOG="%s/hci3/log"\nPBX_PORTS="8887"\nSBC_PORTS="127.0.0.3:1"\nSBC_DOCKER_CMD=none\n' "$T" "$T" "$T" > "$T/hci3/config.conf"
out=$(PATH="$T/stubs:$PATH" CFG_DIR="$T/hci3" SYSTEMD_RUN_DIR="$T/khong" bash "$ROOT/bin/health-check.sh" 2>&1)
check "PBX_SSH để trống (cùng VM): không báo lỗi này dù PBX_PORTS không có IP" '! echo "$out" | grep -q "PBX_SSH đã đặt"'

echo; echo "KẾT QUẢ: $ok đạt, $bad lỗi"
[ "$bad" -eq 0 ]
