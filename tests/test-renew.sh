#!/bin/bash
set -u
S="${S:-$(cd "$(dirname "$0")/../bin" && pwd)/set-renew-days.sh}"; CADDY="${CADDY:-$(command -v caddy)}"
[ -x "$CADDY" ] || { echo "Cần Caddy (đặt CADDY=/đường/dẫn/caddy) để chạy bài này"; exit 0; }
T=/tmp/rtest; rm -rf $T; mkdir -p $T/cfg $T/data
cat > $T/Caddyfile.orig << C
{
    email kieuthuong@etelecom.vn
    storage file_system $T/data
}

sip-dev-v22.etelecom.vn {
    respond "ok" 200
}
C
cp $T/Caddyfile.orig $T/Caddyfile
printf '#!/bin/bash\necho reload >> %s/reload.log\nexit ${STUB_RELOAD_RC:-0}\n' $T > $T/reload.sh; chmod +x $T/reload.sh
printf '#!/bin/bash\nexit 1\n' > $T/badcaddy; chmod +x $T/badcaddy
setcfg() { printf 'RENEW_DAYS_BEFORE_EXPIRY=%s\nCERT_LIFETIME_DAYS=%s\n' "$1" "${2:-90}" > $T/cfg/config.conf; }
run() { CFG_DIR=$T/cfg CADDYFILE=$T/Caddyfile CADDY_BIN=${CB:-$CADDY} RELOAD_CMD=$T/reload.sh CADDY_ACTIVE_CMD=true bash $S "$@" 2>&1; }
ok=0; bad=0
check() { if eval "$2"; then echo "  OK   $1"; ok=$((ok+1)); else echo "  FAIL $1"; bad=$((bad+1)); fi; }
reloads() { [ -f $T/reload.log ] && wc -l < $T/reload.log || echo 0; }
ratio() { $CADDY adapt --config $T/Caddyfile 2>/dev/null | jq -r '.apps.tls.automation.policies[0].renewal_window_ratio // "không có"'; }

echo "== R1 chèn lần đầu (45/90 = 0.5)"
setcfg 45; chmod 640 $T/Caddyfile; before=$(stat -c %a $T/Caddyfile); out=$(run); echo "     $out" | cut -c1-120
check "thêm đúng một dòng vào khối toàn cục" '[ "$(grep -c renewal_window_ratio $T/Caddyfile)" = 1 ] && sed -n 2p $T/Caddyfile | grep -q "renewal_window_ratio 0.5000"'
check "Caddy thật đọc ra ratio 0.5" '[ "$(ratio)" = 0.5 ]'
check "đã reload một lần, có bản sao lưu" '[ "$(reloads)" = 1 ] && ls $T/Caddyfile.bak-* >/dev/null 2>&1'
check "quyền file giữ nguyên" '[ "$(stat -c %a $T/Caddyfile)" = "$before" ]'
check "phần còn lại của Caddyfile không đổi" 'diff <(grep -v renewal_window_ratio $T/Caddyfile) $T/Caddyfile.orig >/dev/null'

echo "== R2 chạy lại cùng giá trị"
out=$(run); check "báo đã đúng sẵn, không reload thêm" 'echo "$out" | grep -q "Đã đúng sẵn" && [ "$(reloads)" = 1 ]'

echo "== R3 đổi sang 60 ngày"
setcfg 60; out=$(run)
check "thay dòng cũ (vẫn chỉ một dòng) và reload" '[ "$(grep -c renewal_window_ratio $T/Caddyfile)" = 1 ] && grep -q "renewal_window_ratio 0.6667" $T/Caddyfile && [ "$(reloads)" = 2 ]'
check "Caddy thật đọc ra 0.6667" '[ "$(ratio)" = 0.6667 ]'

echo "== R4 10 ngày: không có tác dụng với Let's Encrypt"
cp $T/Caddyfile.orig $T/Caddyfile; rm -f $T/reload.log; setcfg 10; out=$(run); rc=$?
echo "$out" | head -2 | cut -c1-140 | sed 's/^/     /'
check "từ chối (mã 3), không sửa file, không reload" 'run >/dev/null; [ $? = 3 ] && diff $T/Caddyfile $T/Caddyfile.orig >/dev/null && [ "$(reloads)" = 0 ]'
out=$(run --force); check "--force: vẫn đặt 0.1111" 'grep -q "renewal_window_ratio 0.1111" $T/Caddyfile && [ "$(ratio)" = 0.1111 ]'

echo "== R5 giá trị không hợp lệ"
cp $T/Caddyfile.orig $T/Caddyfile; rm -f $T/reload.log
for v in 0 90 abc 91 ""; do setcfg "$v"; out=$(run); rc=$?
  check "RENEW_DAYS='$v' bị từ chối, file không đổi" '[ $rc != 0 ] && diff $T/Caddyfile $T/Caddyfile.orig >/dev/null'; done
check "không reload lần nào" '[ "$(reloads)" = 0 ]'

echo "== R6 Caddyfile không có khối toàn cục ở đầu"
printf 'sip-dev-v22.etelecom.vn {\n    respond "ok" 200\n}\n' > $T/Caddyfile; cp $T/Caddyfile $T/nogl; setcfg 45; out=$(run)
check "từ chối, không tự tạo khối, file không đổi" 'echo "$out" | grep -q "không bắt đầu bằng khối" && diff $T/Caddyfile $T/nogl >/dev/null'
printf '# chú thích\n\n{\n    email a@b.c\n    storage file_system %s\n}\nx.example {\n    respond ok\n}\n' $T/data > $T/Caddyfile; out=$(run)
check "có chú thích đứng trước khối toàn cục vẫn chèn đúng" 'grep -q "renewal_window_ratio 0.5000" $T/Caddyfile'

echo "== R7 lỗi thì khôi phục"
cp $T/Caddyfile.orig $T/Caddyfile; rm -f $T/reload.log; setcfg 45
out=$(CB=$T/badcaddy run); check "validate lỗi: khôi phục file gốc, không reload" 'diff $T/Caddyfile $T/Caddyfile.orig >/dev/null && [ "$(reloads)" = 0 ] && echo "$out" | grep -q "Đã khôi phục"'
out=$(STUB_RELOAD_RC=1 run); check "reload lỗi: khôi phục file gốc" 'diff $T/Caddyfile $T/Caddyfile.orig >/dev/null && echo "$out" | grep -q "reload lỗi"'

echo "== R8 Caddy đang không chạy"
out=$(CF=1 CFG_DIR=$T/cfg CADDYFILE=$T/Caddyfile CADDY_BIN=$CADDY RELOAD_CMD=$T/reload.sh CADDY_ACTIVE_CMD=false bash $S 2>&1); rm -f $T/reload.log
check "đặt cấu hình, không reload, báo rõ" 'grep -q "renewal_window_ratio 0.5000" $T/Caddyfile && echo "$out" | grep -q "đang không chạy" && [ "$(reloads)" = 0 ]'
echo; echo "KẾT QUẢ: $ok đạt, $bad lỗi"
