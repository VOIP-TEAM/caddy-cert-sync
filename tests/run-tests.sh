#!/bin/bash
set -u
export T=/tmp/ctest; rm -rf $T; mkdir -p $T/{cfg,lib,stubs,run,pbx,state,caddy/certificates/acme-v02.test/sip-dev.test,certs}
BIN="${BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}"
cp $BIN/lib-window.sh $BIN/lib-live.sh $BIN/lib-sbc-api.sh $BIN/lib-remote.sh $T/lib/
cat > $T/lib/lib-notify.sh << 'N'
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
notify_telegram() { printf '%s\n----\n' "$1" >> "$T/tg.log"; return 0; }
N
cat > $T/cfg/config.conf << C
DOMAIN="sip-dev.test"
CADDY_CERT_BASE="$T/caddy"
PBX_CRT="$T/pbx/portsip.crt"; PBX_KEY="$T/pbx/portsip.key"
PORTSIP_UID=$(id -u); PORTSIP_GID=$(id -g)
WINDOW_START=0; WINDOW_END=24
STATE_DIR="$T/state"; LOG="$T/log"
PBX_PORTS="18443"; SBC_PORTS="18883"
PBX_RESTART_CONTAINERS="portsip.webserver"
SBC_API_BASE="https://127.0.0.1:8883/sbc/api"; SBC_TOKEN_JQ='.data.token'
SBC_TLS_DOMAIN="sip-dev.test"; SBC_WEB_DOMAIN=true; SBC_DELETE_FIRST=true
SBC_FALLBACK_RESTART="nginx"
C
cat > $T/cfg/sbc.cred << 'C'
SBC_USER="admin"
SBC_PASS='p@ss "quote" $dollar \back'
C
cat > $T/stubs/srv.sh << 'S'
#!/bin/bash
R=$T/run
case $1 in
 stop) [ -f $R/$2.pid ] && kill $(cat $R/$2.pid) 2>/dev/null; rm -f $R/$2.pid; sleep 0.4;;
 start) "$0" stop $2; openssl s_server -accept $3 -cert $4 -key $5 -www -quiet >/dev/null 2>&1 9>&- & echo $! > $R/$2.pid; sleep 0.6;;
esac
S
cat > $T/stubs/docker << 'S'
#!/bin/bash
echo "docker $*" >> $T/docker.log
[ "${STUB_DOCKER_FAIL:-}" == 1 ] && [ "$1" == restart ] && { echo 'Error response from daemon: No such container: portsip.webserver' >&2; exit 1; }
[ "$1" == restart ] && { [ "${STUB_DOCKER_BREAK:-}" == 1 ] || $T/stubs/srv.sh start pbx "${PBX_SERVE_BIND:-18443}" "${PBX_SERVE_CRT:-$T/pbx/portsip.crt}" "${PBX_SERVE_KEY:-$T/pbx/portsip.key}"; }
exit 0
S
cat > $T/stubs/curl << 'S'
#!/bin/bash
url="${@: -1}"; body=""; prev=""; outfile=""; wfmt=""
for a in "$@"; do
  [ "$prev" == "-d" ] && body="${a#@}"
  [ "$prev" == "-o" ] && outfile="$a"
  [ "$prev" == "-w" ] && wfmt="$a"
  [ "$prev" == "-H" ] && [[ "$a" == @* ]] && cat "${a#@}" >> $T/headers.log
  [ "$prev" == "-H" ] && [[ "$a" == Content-Type* ]] && echo "$a" >> $T/ct.log
  prev="$a"
done
echo "curl $url" >> $T/curl.log
case "$url" in
 */AuthUser) jq -r .password "$body" >> $T/pass.log
   if   [ "${STUB_LOGIN_FAIL:-}" == 1 ]; then out='{"code":401,"message":"sai mat khau"}'
   elif [ "${STUB_TOKEN_REAL:-}" == 1 ]; then out='{"access-token":"0123456789abcdef0123456789abcdef","access_token_expires_seconds":1792053410,"key":"user_key:admin","result":"RESULT_SUCCESS","role":"Admin"}'
   elif [ "${STUB_TOKEN_ALT:-}" == 1 ]; then out='{"code":0,"result":{"access_token":"0123456789abcdef0123456789abcdef"}}'
   else out='{"data":{"token":"tok123"}}'; fi
   if [ -n "$outfile" ]; then printf '%s' "$out" > "$outfile"; [ -n "$wfmt" ] && printf '200'; else echo "$out"; fi;;
 */DeleteCert) cp "$body" $T/delete.json; $T/stubs/srv.sh stop sbc; echo '{"code":0}';;
 */AddCert) cp "$body" $T/addcert.json; jq -r .cert "$body" > $T/sbc-add.crt; jq -r .private_key "$body" > $T/sbc-add.key
   posted=$(openssl x509 -noout -serial -in $T/sbc-add.crt 2>/dev/null | cut -d= -f2)
   if [ "${STUB_SBC_BREAK:-}" == 1 ] && [ "$posted" == "$(cat $T/state/staged/serial 2>/dev/null)" ]; then echo '{"code":500,"message":"loi gia lap"}'; else $T/stubs/srv.sh start sbc ${SBC_BIND:-18883} $T/sbc-add.crt $T/sbc-add.key; echo '{"code":0}'; fi;;
esac
S
chmod +x $T/stubs/*
# ssh giả: chạy pbx-agent.sh như khi sshd dùng lệnh bắt buộc (SSH_ORIGINAL_COMMAND), với "VM PBX" nằm ở $T/remote
cat > $T/stubs/ssh << 'S'
#!/bin/bash
cmd="${@: -1}"; host="${@: -2:1}"
echo "$host :: $cmd" >> "$T/ssh.log"
[ "${STUB_SSH_DOWN:-}" == 1 ] && { echo "ssh: connect to host pbx-vm port 22: Connection refused" >&2; exit 255; }
SSH_ORIGINAL_COMMAND="$cmd" AGENT_CONF="$T/remote/agent.conf" AGENT_LOCK="$T/remote/lock" AGENT_LOG="$T/remote/agent.log" \
  PBX_SERVE_BIND=127.0.0.2:18443 PBX_SERVE_CRT="$T/remote/pbx/portsip.crt" PBX_SERVE_KEY="$T/remote/pbx/portsip.key" \
  exec bash "$PBX_AGENT_BIN"
S
chmod +x $T/stubs/ssh
export PBX_AGENT_BIN="$BIN/pbx-agent.sh"
export PATH=$T/stubs:$PATH CFG_DIR=$T/cfg LIB_DIR=$T/lib POLL=1 WAIT_PBX=6 WAIT_SBC=4 WAIT_FALLBACK=3

# --- CA giả: root -> intermediate -> leaf (khoá EC dạng SEC1 như Caddy) ---
cd $T/certs
mkca() { # $1=tên $2=CN
  openssl ecparam -name prime256v1 -genkey -noout -out $1.key 2>/dev/null
}
mkca root; openssl req -x509 -new -key root.key -subj "/CN=Test Root" -days 30 -out root.crt 2>/dev/null
mkca int;  openssl req -new -key int.key -subj "/CN=Test Int" -out int.csr 2>/dev/null
openssl x509 -req -in int.csr -CA root.crt -CAkey root.key -set_serial 0x9 -days 30 -out int.crt -extfile <(echo "basicConstraints=CA:TRUE") 2>/dev/null
mkca sint; openssl req -new -key sint.key -subj "/CN=(STAGING) Fake Int" -out sint.csr 2>/dev/null
openssl x509 -req -in sint.csr -CA root.crt -CAkey root.key -set_serial 0xA -days 30 -out sint.crt -extfile <(echo "basicConstraints=CA:TRUE") 2>/dev/null
leaf() { # $1=tên $2=serial $3=intermediate
  mkca $1; openssl req -new -key $1.key -subj "/CN=sip-dev.test" -out $1.csr 2>/dev/null
  openssl x509 -req -in $1.csr -CA $3.crt -CAkey $3.key -set_serial $2 -days 30 -out $1.crt -extfile <(echo "subjectAltName=DNS:sip-dev.test") 2>/dev/null
}
leaf old 0x1111 int; leaf new 0x2222 int; leaf stg 0x3333 sint; leaf newer 0x4444 int; leaf n5 0x5555 int
D=$T/caddy/certificates/acme-v02.test/sip-dev.test
put_caddy() { cat $1.crt $3.crt root.crt > $D/sip-dev.test.crt; cp $2.key $D/sip-dev.test.key; }

ok=0; bad=0
check() { if eval "$2"; then echo "  OK   $1"; ok=$((ok+1)); else echo "  FAIL $1"; bad=$((bad+1)); fi; }
tgn() { grep -c '^----$' $T/tg.log 2>/dev/null || echo 0; }
DEP=$BIN/cert-deploy.sh
win_closed() { h=$(date +%H | sed 's/^0//'); sed -i "s/^WINDOW_START=.*/WINDOW_START=$(( (h+2) % 24 )); WINDOW_END=$(( (h+3) % 24 )) # đóng/" $T/cfg/config.conf; }
win_open()   { sed -i "s/^WINDOW_START=.*/WINDOW_START=0; WINDOW_END=24 # mở/" $T/cfg/config.conf; }

# trạng thái ban đầu: PBX và SBC đang phục vụ cert cũ
$T/stubs/srv.sh start pbx 18443 $T/certs/old.crt $T/certs/old.key
$T/stubs/srv.sh start sbc 18883 $T/certs/old.crt $T/certs/old.key

echo "== S1 cert staging bị từ chối"
win_closed
put_caddy stg stg sint; $DEP stage
check "không có thông báo" '[ "$(tgn)" = 0 ]'
check "log ghi lý do" 'grep -q "cert staging" $T/log'

echo "== S2 khoá không khớp cert"
put_caddy new old int; $DEP stage
check "không có thông báo" '[ "$(tgn)" = 0 ]'
check "log ghi lý do" 'grep -q "khoá không khớp cert" $T/log'

echo "== S3 chuẩn bị cert hợp lệ"
put_caddy new new int; $DEP stage
check "gửi đúng 1 thông báo [1/2]" '[ "$(tgn)" = 1 ] && grep -q "\[1/2\]" $T/tg.log'
check "serial đã chuẩn bị = 2222" '[ "$(cat $T/state/staged/serial)" = 2222 ]'
check "chuỗi chỉ còn 2 cert (đã bỏ cert gốc)" '[ "$(grep -c "BEGIN CERTIFICATE" $T/state/staged/chain.pem)" = 2 ]'
check "chuỗi bắt đầu bằng cert domain" '[ "$(openssl x509 -in $T/state/staged/chain.pem -noout -serial | cut -d= -f2)" = 2222 ]'
check "chưa đụng file PBX" '[ ! -e $T/pbx/portsip.crt ]'
check "chưa gọi API SBC" '[ ! -e $T/curl.log ]'
check "chưa restart container" '[ ! -e $T/docker.log ]'
check "đã ghi dấu CHỜ ÁP DỤNG kèm serial và thời điểm phát hiện" '[ -f $T/state/pending ] && grep -q "^serial=2222$" $T/state/pending && grep -q "^detected=" $T/state/pending && grep -q "^notbefore=" $T/state/pending'
check "[1/2] ghi rõ lần đầu và dấu chờ" 'grep -q "lần đầu" $T/tg.log && grep -q "CHỜ ÁP DỤNG" $T/tg.log'
$DEP stage
check "chạy lại cùng serial: không gửi thêm [1/2]" '[ "$(tgn)" = 1 ]'

echo "== S4 status"
out=$($DEP status); echo "$out" | sed 's/^/     /'
check "PBX và SBC đang phục vụ serial cũ 1111" 'echo "$out" | grep -c "\-> 1111" | grep -q 2'
check "status hiện ĐANG CHỜ ÁP DỤNG" 'echo "$out" | grep -q "ĐANG CHỜ ÁP DỤNG"'

echo "== S5 áp dụng thủ công (now)"
win_open
$DEP now --force; rc=$?
check "mã thoát 0" '[ $rc = 0 ]'
check "PBX: chép chain + key rồi restart đúng 1 container (portsip.webserver), không đụng wsspublisher" 'grep -q "restart -t 300 portsip.webserver$" $T/docker.log && ! grep -q wsspublisher $T/docker.log && [ -s $T/pbx/portsip.crt ] && [ -s $T/pbx/portsip.key ]'
check "SBC: gọi AuthUser, DeleteCert, AddCert đúng thứ tự" '[ "$(grep -o "[A-Za-z]*$" $T/curl.log | tr "\n" " ")" = "AuthUser DeleteCert AddCert " ]'
check "SBC: token đi qua header access-token" 'grep -q "access-token: tok123" $T/headers.log'
check "SBC: mật khẩu có ký tự đặc biệt được gửi nguyên vẹn" '[ "$(cat $T/pass.log)" = "p@ss \"quote\" \$dollar \\back" ]'
check "AddCert: đủ trường và chuỗi 2 cert" 'jq -e ".tls_domain==\"sip-dev.test\" and .for_sbc_web_domain==true and .description==\"sip-dev.test\"" $T/addcert.json >/dev/null && [ "$(jq -r .cert $T/addcert.json | grep -c "BEGIN CERTIFICATE")" = 2 ] && jq -r .private_key $T/addcert.json | head -1 | grep -q "BEGIN PRIVATE KEY"'
check "DeleteCert: đúng khoá pcert_key:<domain>" '[ "$(jq -r .key $T/delete.json)" = "pcert_key:sip-dev.test" ]'
check "gửi [2/2] THÀNH CÔNG" 'tail -18 $T/tg.log | grep -q "\[2/2\].*THÀNH CÔNG"'
check "đã lưu bản applied/ để hoàn tác" '[ "$(cat $T/state/applied/serial)" = 2222 ]'
check "dấu chờ đã xoá, ghi nhận lần áp dụng" '[ ! -f $T/state/pending ] && grep -q "serial=2222" $T/state/applied-at'
out=$($DEP status); check "cả hai bên phục vụ 2222" 'echo "$out" | grep -c "\-> 2222" | grep -q 2'
check "status báo không có cert chờ" 'echo "$out" | grep -q "không có cert chờ"'
$DEP now --force; rc=$?
check "chạy lại khi đã đúng: mã 2, không restart thêm" '[ $rc = 2 ] && [ "$(grep -c "restart -t" $T/docker.log)" = 1 ]'

echo "== S6 AddCert lỗi: giới hạn số lần thử tự động, hoàn tác, cảnh báo một lần"
rm -f $T/docker.log $T/curl.log; n0=$(tgn)
win_closed; put_caddy newer newer int; $DEP stage; win_open
export STUB_SBC_BREAK=1
$DEP apply; $DEP apply; $DEP apply; $DEP apply
check "PBX: mỗi lần thử restart 2 lần (đổi cert, rồi hoàn tác vì SBC lỗi): 2 lần thử là 4 restart" '[ "$(grep -c "restart -t" $T/docker.log)" = 4 ]'
check "S6 tin ghi lần thử 1/2 và 2/2, kết quả đã hoàn tác cả hai, dự báo bước tiếp theo" 'grep -q "Lần thử tự động: 1/2" $T/tg.log && grep -q "Lần thử tự động: 2/2" $T/tg.log && grep -q "Kết quả: ĐÃ HOÀN TÁC: PBX và SBC đều phục vụ cert cũ" $T/tg.log && grep -q "Sẽ tự thử lại (còn 1 lượt)" $T/tg.log && grep -q "Đã dùng hết 2 lượt tự động" $T/tg.log'
check "S6 PBX được đưa về cert trước (2222) sau mỗi lần lỗi" '[ "$(openssl x509 -noout -serial -in $T/pbx/portsip.crt | cut -d= -f2)" = 2222 ] && grep -q "PBX: ĐÃ HOÀN TÁC vì SBC lỗi" $T/tg.log' 
check "SBC được thử đúng 2 lần AddCert + 2 lần hoàn tác" '[ "$(grep -c AddCert $T/curl.log)" = 4 ]'
check "hoàn tác dùng lại cert 2222 đã lưu" '[ "$(openssl x509 -in $T/sbc-add.crt -noout -serial | cut -d= -f2)" = 2222 ]'
check "có 2 thông báo [2/2] CÓ LỖI" '[ "$(grep -c "CÓ LỖI" $T/tg.log)" = 2 ]'
check "có đúng 1 cảnh báo dừng tự động" '[ "$(grep -c "dừng áp dụng tự động" $T/tg.log)" = 1 ]'
check "dấu chờ vẫn còn sau các lần lỗi, kèm last_failed" '[ -f $T/state/pending ] && grep -q "^last_failed=" $T/state/pending'
check "[1/2] dùng nhãn Caddy đã cấp cert mới khi serial đổi" 'grep -q "Caddy đã cấp cert mới" $T/tg.log'

echo "== S7 sửa lỗi rồi chạy tay: bỏ qua giới hạn"
unset STUB_SBC_BREAK
$DEP now --force; rc=$?
check "thành công, mã 0" '[ $rc = 0 ]'
out=$($DEP status); check "cả hai bên phục vụ 4444" 'echo "$out" | grep -c "\-> 4444" | grep -q 2'
check "bộ đếm lần thử được xoá" '[ -z "$(ls $T/state/attempts-* 2>/dev/null)" ]'
check "dấu chờ được xoá" '[ ! -f $T/state/pending ]'

echo "== S8 cảnh báo cert kẹt"
win_closed; put_caddy new new int; $DEP stage
touch -d "30 hours ago" $T/state/pending
n1=$(grep -c "chưa được áp dụng sau" $T/tg.log); $DEP stuck; $DEP stuck
check "chỉ cảnh báo kẹt 1 lần" '[ "$(grep -c "chưa được áp dụng sau" $T/tg.log)" = $((n1+1)) ]'

echo "== S9 renew rơi đúng vào khung giờ: chuẩn bị rồi áp dụng ngay"
win_open; rm -f $T/docker.log; n2=$(tgn)
put_caddy n5 n5 int; $DEP stage
check "restart container PBX ngay" '[ "$(grep -c "restart -t" $T/docker.log)" = 1 ]'
check "đủ cặp [1/2] và [2/2]" '[ "$(tgn)" = $((n2+2)) ] && tail -34 $T/tg.log | grep -q "\[1/2\]" && tail -18 $T/tg.log | grep -q "\[2/2\].*THÀNH CÔNG"'
out=$($DEP status); check "cả hai bên phục vụ 5555" 'echo "$out" | grep -c "\-> 5555" | grep -q 2'
check "dấu chờ được xoá sau khi áp dụng" '[ ! -f $T/state/pending ]'

echo "== S10 không có cert chờ: hệ thống KHÔNG tự thay, chỉ cảnh báo lệch; now --force mới ép được"
rm -f $T/docker.log $T/curl.log; n3=$(tgn)
$T/stubs/srv.sh start sbc 18883 $T/certs/old.crt $T/certs/old.key
check "trước khi chạy: không có dấu chờ, SBC đang ở cert cũ" '[ ! -f $T/state/pending ] && [ "$(openssl s_client -connect 127.0.0.1:18883 </dev/null 2>/dev/null | openssl x509 -noout -serial | cut -d= -f2)" = 1111 ]'
$DEP apply
check "S10 apply tự động không thay gì: không restart, không gọi API, không gửi tin" '[ ! -e $T/docker.log ] && [ ! -e $T/curl.log ] && [ "$(tgn)" = "$n3" ]'
$DEP now; rc=$?
check "S10 now khi không có cert chờ: mã 2, không thay gì" '[ $rc = 2 ] && [ ! -e $T/docker.log ] && [ ! -e $T/curl.log ]'
$DEP stuck
check "S10 stuck báo lệch đúng một lần và ghi rõ hệ thống không tự thay" '[ "$(tgn)" = $((n3+1)) ] && tail -22 $T/tg.log | grep -q "cổng không phục vụ đúng cert đã chuẩn bị" && tail -22 $T/tg.log | grep -q "now --force"'
$DEP stuck
check "S10 không báo lệch lặp" '[ "$(tgn)" = $((n3+1)) ]'
$DEP now --force; rc=$?
out=$($DEP status); check "S10 now --force ép thay: SBC về 5555, PBX đã đúng nên không restart" '[ $rc = 0 ] && echo "$out" | grep -c "\-> 5555" | grep -q 2 && [ ! -e $T/docker.log ]'
$DEP stuck; check "S10 hết lệch: dấu cảnh báo lệch được xoá" '[ -z "$(ls $T/state | grep drift-alerted)" ]'

echo "== S11 dấu chờ còn nhưng cổng đã đúng: xoá dấu, không restart"
rm -f $T/docker.log $T/curl.log; echo "serial=5555" > $T/state/pending
$DEP now --force; rc=$?
check "mã 2 (không có gì cần áp dụng), dấu chờ bị xoá, không restart, không gọi API" '[ $rc = 2 ] && [ ! -f $T/state/pending ] && [ ! -e $T/docker.log ] && [ ! -e $T/curl.log ]'

echo "== S12 stage lỗi kéo dài: báo Telegram một lần, tự xoá khi hết lỗi"
win_closed; export STAGE_ALERT_SECS=2; n6=$(tgn)
put_caddy new old int; $DEP stage
check "lần đầu: ghi dấu lỗi nhưng chưa báo (có thể tạm thời)" '[ -f $T/state/stage-fail ] && [ "$(tgn)" = $n6 ]'
sleep 3; $DEP stage
check "kéo dài quá ngưỡng: báo đúng một lần" '[ "$(tgn)" = $((n6+1)) ] && tail -18 $T/tg.log | grep -q "không chuẩn bị được cert mới"'
$DEP stage
check "không báo lặp" '[ "$(tgn)" = $((n6+1)) ]'
put_caddy new new int; $DEP stage
check "hết lỗi: xoá dấu lỗi, chuẩn bị bình thường" '[ ! -f $T/state/stage-fail ] && [ "$(cat $T/state/staged/serial)" = 2222 ]'
unset STAGE_ALERT_SECS

echo "== S13 khoá chống chạy chồng"
win_open; rm -f $T/docker.log $T/curl.log
( flock $T/state/.lock sleep 5 ) & sleep 1
$DEP apply
check "apply bỏ qua khi đang có lần chạy khác, không đụng PBX/SBC" '[ ! -e $T/docker.log ] && [ ! -e $T/curl.log ] && grep -q "Đang có một lần chạy khác" $T/log'
t0=$(date +%s); $DEP now --force; rc=$?; t1=$(date +%s)
check "now đợi khoá rồi chạy (mất ít nhất 3 giây) và áp dụng thành công" '[ $((t1-t0)) -ge 3 ] && [ $rc = 0 ]'
wait
out=$($DEP status); check "cả hai bên phục vụ 2222" 'echo "$out" | grep -c "\-> 2222" | grep -q 2'

echo "== S14 ghi file chuẩn bị lỗi (mô phỏng ổ đầy): không làm hỏng bản đang có"
win_closed; mkdir -p $T/stubs2
cat > $T/stubs2/cp << 'S'
#!/bin/bash
case "${@: -1}" in *key.raw.pem) exit 1;; esac
exec /bin/cp "$@"
S
chmod +x $T/stubs2/cp
prev_serial=$(cat $T/state/staged/serial)
put_caddy newer newer int
PATH=$T/stubs2:$PATH $DEP stage
check "bản đã chuẩn bị trước đó còn nguyên, không để lại thư mục dở" '[ "$(cat $T/state/staged/serial)" = "$prev_serial" ] && [ ! -d $T/state/staged.new ]'
check "ghi lý do vào log" 'grep -q "không ghi đủ các file chuẩn bị" $T/log'
$DEP stage
check "hết lỗi: chuẩn bị bình thường, xoá dấu lỗi" '[ "$(cat $T/state/staged/serial)" = 4444 ] && [ ! -f $T/state/stage-fail ]'

echo "== S15 watcher ghi log khi stage thoát lỗi và vẫn chạy tiếp"
W=/tmp/wtest2; rm -rf $W; mkdir -p $W/caddy/certificates $W/cfg $W/bin
echo "CADDY_CERT_BASE=\"$W/caddy\"; LOG=\"$W/log\"" > $W/cfg/config.conf
printf '#!/bin/bash\nexit 3\n' > $W/bin/cert-deploy.sh; chmod +x $W/bin/cert-deploy.sh
( CFG_DIR=$W/cfg LIB_DIR=$W/bin WATCH_TIMEOUT=2 timeout 7 bash $BIN/watch-caddy-cert.sh ) >/dev/null 2>&1
check "log ghi mã lỗi 3 và watcher gọi lại nhiều lần" '[ "$(grep -c "stage thoát với mã 3" $W/log)" -ge 2 ]'

echo "== S16-S20 lý do thất bại được ghi vào log và gửi trong [2/2]"
reset_old() { mkdir -p $T/pbx; cp $T/certs/old.crt $T/pbx/portsip.crt; cp $T/certs/old.key $T/pbx/portsip.key; rm -f $T/pbx/*.prev $T/pbx/*.new; $T/stubs/srv.sh start pbx 18443 $T/certs/old.crt $T/certs/old.key; $T/stubs/srv.sh start sbc 18883 $T/certs/old.crt $T/certs/old.key; rm -f $T/docker.log $T/curl.log; }
win_open
reset_old; STUB_DOCKER_FAIL=1 $DEP now --force >/dev/null
check "S16 docker restart lỗi: tin ghi lý do PBX, SBC được bỏ qua (giữ cert cũ cho đồng nhất)" 'tail -22 $T/tg.log | grep -q "PBX: THẤT BẠI (docker restart lỗi" && tail -22 $T/tg.log | grep -q "SBC: BỎ QUA" && [ ! -e $T/curl.log ]'
check "S16 log có lý do và lỗi gốc của docker" 'grep -q "PBX: docker restart lỗi" $T/log && grep -q "No such container" $T/log'
reset_old; STUB_DOCKER_BREAK=1 $DEP now --force >/dev/null
check "S17 restart xong nhưng cổng không đổi: tin ghi serial từng cổng" 'tail -22 $T/tg.log | grep -q "đã restart nhưng cổng PBX chưa phục vụ serial 4444" && tail -22 $T/tg.log | grep -q "18443=1111"'
cp $T/cfg/config.conf $T/cfg/config.conf.keep; touch $T/afile
sed -i "s#^PBX_CRT=.*#PBX_CRT=\"$T/afile/portsip.crt\"; PBX_KEY=\"$T/afile/portsip.key\"#" $T/cfg/config.conf
reset_old; $DEP now --force >/dev/null
check "S18 không chép được file PBX: tin ghi đúng lý do và không restart container" 'tail -22 $T/tg.log | grep -q "không chép được cert lên VM PBX" && tail -22 $T/tg.log | grep -q "Chưa thay đổi gì" && [ ! -e $T/docker.log ]'
cp $T/cfg/config.conf.keep $T/cfg/config.conf
reset_old; STUB_LOGIN_FAIL=1 $DEP now --force >/dev/null
check "S19 đăng nhập API SBC thất bại: tin ghi lý do, mã HTTP và phản hồi thật" 'tail -22 $T/tg.log | grep -q "SBC: THẤT BẠI (đăng nhập API thất bại (HTTP 200" && tail -22 $T/tg.log | grep -q "sai mat khau"'
check "S19 PBX đã đổi trước đó thì được hoàn tác vì SBC lỗi, SBC chưa bị đụng tới" 'tail -22 $T/tg.log | grep -q "PBX: ĐÃ HOÀN TÁC vì SBC lỗi" && tail -22 $T/tg.log | grep -q "Kết quả: ĐÃ HOÀN TÁC" && [ "$(grep -c DeleteCert $T/curl.log)" = 0 ]'
reset_old; STUB_SBC_BREAK=1 $DEP now --force >/dev/null
check "S20 AddCert trả lỗi: tin kèm phản hồi thật của API và serial từng cổng" 'tail -22 $T/tg.log | grep -q "loi gia lap" && tail -22 $T/tg.log | grep -q "18883="'
check "S20 ghi cả vào log" 'grep -q "SBC: sau AddCert, cổng SBC chưa phục vụ serial" $T/log'

echo "== S21 token nằm ở trường khác: báo đường dẫn ứng viên, không lộ token, rồi chuỗi API chạy được khi đã chỉnh"
reset_old; rm -f $T/headers.log; n7=$(tgn)
STUB_TOKEN_ALT=1 $DEP now --force >/dev/null
exp1='.["result"]["access_token"]'
check "S21 đăng nhập thất bại nhưng tin chỉ ra biểu thức chứa token" 'tail -22 $T/tg.log | grep -qF "chuỗi giống token nằm ở $exp1" && tail -22 $T/tg.log | grep -qF "SBC_TOKEN_JQ='"'"'$exp1'"'"'"'
check "S21 token bị ẩn trong tin và trong log" '! grep -q "0123456789abcdef0123456789abcdef" $T/tg.log && ! grep -q "0123456789abcdef0123456789abcdef" $T/log && tail -22 $T/tg.log | grep -q "ẩn 32 ký tự"'
cp $T/cfg/config.conf $T/cfg/config.conf.keep2; echo "SBC_TOKEN_JQ='.result.access_token'" >> $T/cfg/config.conf
reset_old; rm -f $T/headers.log
STUB_TOKEN_ALT=1 $DEP now --force >/dev/null; rc=$?
check "S21 sau khi chỉnh SBC_TOKEN_JQ: đăng nhập được và token đó được dùng cho DeleteCert và AddCert" '[ $rc = 0 ] && [ "$(grep -c "access-token: 0123456789abcdef0123456789abcdef" $T/headers.log)" = 2 ]'
cp $T/cfg/config.conf.keep2 $T/cfg/config.conf


echo "== S22 phản hồi đăng nhập thật của PortSIP: token ở khoá access-token (có dấu gạch ngang)"
exp2='.["access-token"]'
reset_old; rm -f $T/headers.log
STUB_TOKEN_REAL=1 $DEP now --force >/dev/null
check "S22a cấu hình sai (.data.token): gợi ý đúng biểu thức dạng ngoặc vuông, không gợi ý .access-token" 'tail -22 $T/tg.log | grep -qF "chuỗi giống token nằm ở $exp2" && ! tail -22 $T/tg.log | grep -qF "SBC_TOKEN_JQ='"'"'.access-token'"'"'"'
check "S22a token không lộ trong tin và log" '! grep -q "0123456789abcdef0123456789abcdef" $T/tg.log && ! grep -q "0123456789abcdef0123456789abcdef" $T/log'
cp $T/cfg/config.conf $T/cfg/config.conf.keep3
sed -i "/^SBC_API_BASE=/s/; SBC_TOKEN_JQ='.data.token'//" $T/cfg/config.conf
check "S22b cấu hình không còn SBC_TOKEN_JQ" '! grep -q "SBC_TOKEN_JQ" $T/cfg/config.conf'
reset_old; rm -f $T/headers.log
STUB_TOKEN_REAL=1 $DEP now --force >/dev/null; rc=$?
check "S22b không đặt SBC_TOKEN_JQ: mặc định đã là access-token, đăng nhập được và token đi vào DeleteCert, AddCert" '[ $rc = 0 ] && [ "$(grep -c "access-token: 0123456789abcdef0123456789abcdef" $T/headers.log)" = 2 ]'
printf '%s\n' "SBC_TOKEN_JQ='.[\"access-token\"]'" >> $T/cfg/config.conf
reset_old; rm -f $T/headers.log
STUB_TOKEN_REAL=1 $DEP now --force >/dev/null; rc=$?
check "S22c đặt tường minh SBC_TOKEN_JQ như hướng dẫn: thành công" '[ $rc = 0 ] && [ "$(grep -c "access-token: 0123456789abcdef0123456789abcdef" $T/headers.log)" = 2 ]'
cp $T/cfg/config.conf.keep3 $T/cfg/config.conf


echo "== S23 một cổng PBX đã đúng cert, cổng kia không phục vụ TLS (đúng tình huống 8887 và 8885 trên máy thật)"
cp $T/cfg/config.conf $T/cfg/config.conf.keep4
printf 'PBX_PORTS="18443 18444"\n' >> $T/cfg/config.conf
reset_old; $DEP now --force >/dev/null
check "S23 tin ghi cổng đúng và cổng không có cert, kèm gợi ý bỏ cổng không phục vụ TLS" 'tail -22 $T/tg.log | grep -q "18443=4444" && tail -22 $T/tg.log | grep -q "18444=không có cert" && tail -22 $T/tg.log | grep -q "bỏ khỏi PBX_PORTS" && tail -22 $T/tg.log | grep -q "SBC: THÀNH CÔNG"'
cp $T/cfg/config.conf.keep4 $T/cfg/config.conf
reset_old; $DEP now --force >/dev/null; rc=$?
check "S23 bỏ cổng sai khỏi danh sách: áp dụng thành công" '[ $rc = 0 ] && tail -22 $T/tg.log | grep -q "PBX: THÀNH CÔNG"'
$DEP now --force >/dev/null; rc=$?
check "S23 chạy lại khi mọi cổng đã đúng: không có gì cần áp dụng, dấu chờ đã xoá" '[ $rc = 2 ] && [ ! -f $T/state/pending ]'


echo "== S24 hoãn việc thay cert đến khi cert đang dùng còn ít ngày (DEPLOY_WHEN_DAYS_LEFT)"
cp $T/cfg/config.conf $T/cfg/config.conf.keep5; printf 'DEPLOY_WHEN_DAYS_LEFT=10\n' >> $T/cfg/config.conf
reset_old; win_closed; put_caddy n5 n5 int; $DEP stage
check "S24 [1/2] ghi rõ chỉ thay khi cert đang dùng còn 10 ngày trở xuống" 'tail -20 $T/tg.log | grep -q "Sẽ chỉ thay khi cert đang dùng còn 10 ngày trở xuống (hiện còn 29 ngày)" || tail -20 $T/tg.log | grep -q "Sẽ chỉ thay khi cert đang dùng còn 10 ngày trở xuống (hiện còn 30 ngày)"'
win_open; rm -f $T/docker.log $T/curl.log; n9=$(tgn)
$DEP apply
check "S24 apply tự động hoãn: không restart, không gọi API, dấu chờ còn, không gửi tin" '[ ! -e $T/docker.log ] && [ ! -e $T/curl.log ] && [ -f $T/state/pending ] && [ "$(tgn)" = "$n9" ] && grep -q "Chưa đến hạn thay" $T/log'
$DEP apply
check "S24 lý do hoãn chỉ ghi log một lần trong ngày" '[ "$(grep -c "Chưa đến hạn thay" $T/log)" = 1 ]'
out=$($DEP status); check "S24 status hiện Hoãn thay: bật" 'echo "$out" | grep -q "Hoãn thay : bật"'
touch -d "30 hours ago" $T/state/pending; n10=$(tgn); $DEP stuck
check "S24 không cảnh báo kẹt khi đang hoãn theo thiết kế" '[ "$(tgn)" = "$n10" ]'
$DEP now --force; rc=$?
check "S24 lệnh now bỏ qua hoãn: áp dụng ngay, xoá dấu chờ" '[ $rc = 0 ] && [ ! -f $T/state/pending ] && tail -18 $T/tg.log | grep -q "\[2/2\].*THÀNH CÔNG"'
reset_old; win_closed; put_caddy newer newer int; $DEP stage
sed -i 's/^DEPLOY_WHEN_DAYS_LEFT=10/DEPLOY_WHEN_DAYS_LEFT=40/' $T/cfg/config.conf
win_open; touch -d "30 hours ago" $T/state/pending; n11=$(tgn); $DEP stuck
check "S24 đến hạn (còn ít hơn ngưỡng): cảnh báo kẹt hoạt động lại" '[ "$(tgn)" = $((n11+1)) ] && tail -18 $T/tg.log | grep -q "chưa được áp dụng"'
rm -f $T/docker.log; $DEP apply
check "S24 đến hạn: apply tự động thay cert, xoá dấu chờ" '[ "$(grep -c "restart -t" $T/docker.log)" = 1 ] && [ ! -f $T/state/pending ]'
cp $T/cfg/config.conf.keep5 $T/cfg/config.conf


echo "== S25 SBC ở VM khác: đo theo host:port, SNI riêng cho PBX và SBC, không docker exec"
cp $T/cfg/config.conf $T/cfg/config.conf.keep7
printf 'PBX_SNI="pbx.test"\nSBC_SNI="sbc.test"\nSBC_PORTS="127.0.0.2:18883"\nSBC_DOCKER_CMD=none\n' >> $T/cfg/config.conf
REAL_OPENSSL=$(command -v openssl); mkdir -p $T/stubs3
printf '#!/bin/bash\n[ "$1" == s_client ] && echo "$*" >> %s/ssl.log\nexec %s "$@"\n' "$T" "$REAL_OPENSSL" > $T/stubs3/openssl; chmod +x $T/stubs3/openssl
win_open; win_closed; put_caddy newer newer int; $DEP stage; win_open
$T/stubs/srv.sh start pbx 18443 $T/certs/old.crt $T/certs/old.key; $T/stubs/srv.sh start sbc 127.0.0.2:18883 $T/certs/old.crt $T/certs/old.key
rm -f $T/docker.log $T/curl.log $T/ssl.log
SBC_BIND=127.0.0.2:18883 PATH=$T/stubs3:$PATH $DEP now --force >/dev/null; rc=$?
check "S25 áp dụng thành công khi SBC ở địa chỉ khác (mã 0)" '[ $rc = 0 ]'
out=$(PATH=$T/stubs3:$PATH $DEP status); check "S25 status hiện mục cổng dạng host:port và cả hai bên đúng serial" 'echo "$out" | grep -q "SBC  :127.0.0.2:18883 ->" && [ "$(echo "$out" | grep -c "\-> 4444")" = 2 ]'
check "S25 PBX được đo bằng SNI pbx.test, SBC bằng SNI sbc.test" 'grep -q -- "-connect 127.0.0.1:18443 -servername pbx.test" $T/ssl.log && grep -q -- "-connect 127.0.0.2:18883 -servername sbc.test" $T/ssl.log'
check "S25 chỉ restart container PBX, không có docker exec" 'grep -q "restart -t 300 portsip.webserver" $T/docker.log && ! grep -q " exec " $T/docker.log'
echo "== S26 SBC ở VM khác mà API không đổi cert: thất bại, vẫn không docker exec"
$T/stubs/srv.sh start pbx 18443 $T/certs/old.crt $T/certs/old.key; $T/stubs/srv.sh start sbc 127.0.0.2:18883 $T/certs/old.crt $T/certs/old.key
win_closed; put_caddy n5 n5 int; $DEP stage; win_open; rm -f $T/docker.log; n12=$(tgn)
STUB_SBC_BREAK=1 SBC_BIND=127.0.0.2:18883 $DEP now --force >/dev/null; rc=$?
check "S26 báo lỗi (mã 1), tin ghi serial từng cổng dạng host:port" '[ $rc = 1 ] && tail -22 $T/tg.log | grep -q "127.0.0.2:18883=" && tail -22 $T/tg.log | grep -q "SBC: THẤT BẠI"'
check "S26 không chạy docker exec dù SBC lỗi (vì SBC_DOCKER_CMD=none)" '! grep -q " exec " $T/docker.log'
cp $T/cfg/config.conf.keep7 $T/cfg/config.conf


echo "== S27 nhắc cert đang dùng sắp hết hạn (expiry)"
cp $T/cfg/config.conf $T/cfg/config.conf.keep8
reset_old; rm -f $T/state/pending $T/state/expiry-alerted-*
printf 'EXPIRY_ALERT_DAYS="40 20"\nCERT_SOURCE_NAME="dán thủ công"\n' >> $T/cfg/config.conf
n13=$(tgn); $DEP expiry
check "S27 còn khoảng 29 ngày, mốc 40: báo đúng một lần, ghi domain, số ngày và mốc" '[ "$(tgn)" = $((n13+1)) ] && tail -18 $T/tg.log | grep -q "sắp hết hạn" && tail -18 $T/tg.log | grep -q "sip-dev.test" && tail -18 $T/tg.log | grep -q "mốc cảnh báo 40 ngày"'
check "S27 không có cert chờ: nhắc dán cert mới theo nguồn đã cấu hình" 'tail -18 $T/tg.log | grep -q "paste-cert.sh" && tail -18 $T/tg.log | grep -q "dán thủ công"'
$DEP expiry
check "S27 chạy lại cùng mốc: không báo trùng" '[ "$(tgn)" = $((n13+1)) ]'
sed -i 's/^EXPIRY_ALERT_DAYS=.*/EXPIRY_ALERT_DAYS="40 30"/' $T/cfg/config.conf; $DEP expiry
check "S27 xuống mốc thấp hơn (30): báo thêm một lần" '[ "$(tgn)" = $((n13+2)) ] && tail -18 $T/tg.log | grep -q "mốc cảnh báo 30 ngày"'
touch $T/state/pending; rm -f $T/state/expiry-alerted-*; $DEP expiry
check "S27 đang có cert mới chờ áp dụng: gợi ý chạy now thay vì dán cert" 'tail -18 $T/tg.log | grep -q "chờ áp dụng"'
sed -i 's/^EXPIRY_ALERT_DAYS=.*/EXPIRY_ALERT_DAYS="10 5"/' $T/cfg/config.conf; $DEP expiry
check "S27 còn nhiều hơn mọi mốc: không báo, xoá các dấu đã báo" '[ "$(tgn)" = $((n13+3)) ] && [ "$(ls $T/state | grep -c expiry-alerted)" = 0 ]'
sed -i 's/^EXPIRY_ALERT_DAYS=.*/EXPIRY_ALERT_DAYS="40"/' $T/cfg/config.conf
$T/stubs/srv.sh stop pbx; $T/stubs/srv.sh stop sbc; n14=$(tgn); $DEP expiry; rc=$?
check "S27 không đo được cổng: im lặng, không lỗi" '[ $rc = 0 ] && [ "$(tgn)" = "$n14" ]'
rm -f $T/state/pending $T/state/expiry-alerted-*; cp $T/cfg/config.conf.keep8 $T/cfg/config.conf


echo "== S28 PBX ở VM khác: thay cert qua SSH tới pbx-agent.sh"
cp $T/cfg/config.conf $T/cfg/config.conf.keep9
printf 'PBX_SSH="cert@pbx-vm"\nPBX_PORTS="127.0.0.2:18443"\n' >> $T/cfg/config.conf
mkdir -p $T/remote/pbx
printf 'PBX_CRT="%s/remote/pbx/portsip.crt"\nPBX_KEY="%s/remote/pbx/portsip.key"\nPORTSIP_UID=%s\nPORTSIP_GID=%s\nPBX_RESTART_CONTAINERS="portsip.webserver"\n' "$T" "$T" "$(id -u)" "$(id -g)" > $T/remote/agent.conf
reset_remote() {
    mkdir -p $T/remote/pbx; cp $T/certs/old.crt $T/remote/pbx/portsip.crt; cp $T/certs/old.key $T/remote/pbx/portsip.key
    rm -f $T/remote/pbx/*.prev $T/remote/pbx/*.new; chmod 640 $T/remote/pbx/portsip.crt $T/remote/pbx/portsip.key
    $T/stubs/srv.sh start pbx 127.0.0.2:18443 $T/certs/old.crt $T/certs/old.key; $T/stubs/srv.sh start sbc 18883 $T/certs/old.crt $T/certs/old.key
    rm -f $T/docker.log $T/curl.log $T/ssh.log
}
rser() { openssl x509 -noout -serial -in "$1" | cut -d= -f2; }
WANT=$(cat $T/state/staged/serial); OLD=$(rser $T/certs/old.crt)
rm -rf $T/pbx; mkdir -p $T/pbx; reset_remote
$DEP now --force >/dev/null; rc=$?
check "S28 thay thành công (mã 0), cả PBX và SBC THÀNH CÔNG" '[ $rc = 0 ] && tail -22 $T/tg.log | grep -q "PBX: THÀNH CÔNG" && tail -22 $T/tg.log | grep -q "SBC: THÀNH CÔNG"'
check "S28 file trên VM PBX là cert mới, bản cũ nằm ở .prev, quyền cũ (640) được giữ" '[ "$(rser $T/remote/pbx/portsip.crt)" = "$WANT" ] && [ "$(rser $T/remote/pbx/portsip.crt.prev)" = "$OLD" ] && [ "$(stat -c %a $T/remote/pbx/portsip.crt)" = 640 ]'
check "S28 không đụng file PBX trên máy điều khiển" '[ ! -e $T/pbx/portsip.crt ]'
check "S28 thứ tự gọi agent: ping, put crt, put key, commit, restart" '[ "$(sed "s/.*:: //" $T/ssh.log | tr "\n" ",")" = "ping,put crt,put key,commit,restart," ]'
check "S28 restart đúng một lần trên VM PBX" '[ "$(grep -c "restart -t 300" $T/docker.log)" = 1 ]'

echo "== S29 SSH tới VM PBX không được: không đụng gì, SBC bị bỏ qua"
reset_remote; n15=$(tgn); STUB_SSH_DOWN=1 $DEP now --force >/dev/null; rc=$?
check "S29 báo lỗi (mã 1), nói rõ không nối được và chưa thay đổi gì" '[ $rc = 1 ] && tail -22 $T/tg.log | grep -q "PBX: THẤT BẠI (không nối được VM PBX" && tail -22 $T/tg.log | grep -q "Chưa thay đổi gì"'
check "S29 file PBX còn nguyên, không restart, SBC bị bỏ qua và không có lệnh gọi API" '[ "$(rser $T/remote/pbx/portsip.crt)" = "$OLD" ] && [ ! -e $T/docker.log ] && tail -22 $T/tg.log | grep -q "SBC: BỎ QUA" && [ ! -e $T/curl.log ]'
check "S29 kết quả cuối ghi rõ không thay đổi gì" 'tail -22 $T/tg.log | grep -q "Kết quả: KHÔNG THAY ĐỔI GÌ"'
echo "== S31 restart xong nhưng PBX không nạp cert mới: hoàn tác"
reset_remote; STUB_DOCKER_BREAK=1 $DEP now --force >/dev/null; rc=$?
check "S31 báo lỗi kèm kết quả hoàn tác, PBX phục vụ lại cert cũ" '[ $rc = 1 ] && tail -22 $T/tg.log | grep -q "đã restart nhưng cổng PBX chưa phục vụ serial" && tail -22 $T/tg.log | grep -q "PBX đã phục vụ lại cert trước (serial '$OLD')"'
check "S31 file PBX về lại cert cũ, và đã restart hai lần (đổi, rồi hoàn tác)" '[ "$(rser $T/remote/pbx/portsip.crt)" = "$OLD" ] && [ "$(grep -c "restart -t 300" $T/docker.log)" = 2 ]'
echo "== S32 PBX xong nhưng SBC lỗi thì đưa PBX về cert cũ"
reset_remote; STUB_SBC_BREAK=1 $DEP now --force >/dev/null; rc=$?
check "S32 tin ghi PBX đã hoàn tác vì SBC lỗi, SBC THẤT BẠI" '[ $rc = 1 ] && tail -22 $T/tg.log | grep -q "PBX: ĐÃ HOÀN TÁC vì SBC lỗi" && tail -22 $T/tg.log | grep -q "SBC: THẤT BẠI"'
check "S32 hai bên cùng cert cũ: file PBX cũ, cổng PBX phục vụ cert cũ" '[ "$(rser $T/remote/pbx/portsip.crt)" = "$OLD" ] && [ "$(SNI=sip-dev.test bash -c ". $T/lib/lib-live.sh; live_serial 127.0.0.2:18443")" = "$OLD" ]'
check "S32 restart PBX hai lần" '[ "$(grep -c "restart -t 300" $T/docker.log)" = 2 ]'
echo "== S34 cài lần đầu trên VM PBX (chưa có file) rồi lỗi: không có gì để hoàn tác"
reset_remote; rm -f $T/remote/pbx/portsip.*; $T/stubs/srv.sh stop pbx
STUB_DOCKER_BREAK=1 $DEP now --force >/dev/null; rc=$?
check "S34 tin ghi rõ không có cert cũ để hoàn tác" '[ $rc = 1 ] && tail -22 $T/tg.log | grep -q "không có cert cũ để hoàn tác (lần đầu)"'
echo "== S35 PBX ở máy này (không SSH): cũng được hoàn tác khi lỗi"
cp $T/cfg/config.conf.keep9 $T/cfg/config.conf
mkdir -p $T/pbx; cp $T/certs/old.crt $T/pbx/portsip.crt; cp $T/certs/old.key $T/pbx/portsip.key; reset_old
STUB_DOCKER_BREAK=1 $DEP now --force >/dev/null; rc=$?
check "S35 file PBX tại chỗ được khôi phục về cert cũ, tin ghi kết quả hoàn tác" '[ $rc = 1 ] && [ "$(rser $T/pbx/portsip.crt)" = "$OLD" ] && tail -22 $T/tg.log | grep -q "Hoàn tác: PBX đã phục vụ lại cert trước"'
cp $T/cfg/config.conf.keep9 $T/cfg/config.conf


echo "== S36 lần thay đầu tiên, chưa có mốc hoàn tác SBC: SBC lỗi thì báo CẦN KIỂM TRA TAY và dừng tự thử lại"
win_open; reset_old; rm -rf $T/state/applied $T/state/attempts-*; mkdir -p $T/pbx
cp $T/certs/old.crt $T/pbx/portsip.crt; cp $T/certs/old.key $T/pbx/portsip.key
echo "serial=$(cat $T/state/staged/serial)" > $T/state/pending
n20=$(tgn); STUB_SBC_BREAK=1 $DEP apply
check "S36 tin ghi không có bản cũ để hoàn tác SBC, kết quả CẦN KIỂM TRA TAY" 'tail -26 $T/tg.log | grep -q "KHÔNG có bản cũ để hoàn tác SBC" && tail -26 $T/tg.log | grep -q "Kết quả: CẦN KIỂM TRA TAY"'
check "S36 PBX vẫn được đưa về cert cũ" 'tail -26 $T/tg.log | grep -q "PBX: ĐÃ HOÀN TÁC vì SBC lỗi" && [ "$(openssl x509 -noout -serial -in $T/pbx/portsip.crt | cut -d= -f2)" = 1111 ]'
check "S36 hệ thống DỪNG tự thử lại và nói rõ" 'tail -26 $T/tg.log | grep -q "Hệ thống DỪNG tự thử lại vì cần người kiểm tra"'
n21=$(tgn); r0=$(grep -c "restart -t" $T/docker.log); STUB_SBC_BREAK=1 $DEP apply
check "S36 lượt apply sau không làm gì: không restart thêm, không gửi thêm tin" '[ "$(tgn)" = "$n21" ] && [ "$(grep -c "restart -t" $T/docker.log)" = "$r0" ]'

echo "== S37 baseline: có mốc hoàn tác thì SBC hoàn tác được và xác minh"
$DEP baseline $T/certs/old.crt $T/certs/new.key >/dev/null 2>&1; rc=$?
check "S37 baseline với khoá không khớp: từ chối, không tạo mốc" '[ $rc != 0 ] && [ ! -e $T/state/applied/serial ]'
$DEP baseline $T/khong-co.crt $T/certs/old.key >/dev/null 2>&1; rc=$?
check "S37 baseline với file không đọc được: từ chối" '[ $rc != 0 ] && [ ! -e $T/state/applied/serial ]'
$DEP baseline $T/certs/old.crt $T/certs/old.key >/dev/null; rc=$?
out=$($DEP status)
check "S37 baseline hợp lệ: ghi mốc serial 1111, status hiện mốc" '[ $rc = 0 ] && [ "$(cat $T/state/applied/serial)" = 1111 ] && echo "$out" | grep -q "Mốc hoàn tác SBC: 1111"'
reset_old; rm -f $T/state/attempts-*; cp $T/certs/old.crt $T/pbx/portsip.crt; cp $T/certs/old.key $T/pbx/portsip.key
echo "serial=$(cat $T/state/staged/serial)" > $T/state/pending
STUB_SBC_BREAK=1 $DEP now >/dev/null; rc=$?
check "S37 SBC lỗi: SBC phục vụ lại cert của mốc (đã xác minh), PBX cũng hoàn tác, kết quả ĐÃ HOÀN TÁC" '[ $rc = 1 ] && tail -26 $T/tg.log | grep -q "SBC phục vụ lại cert trước (serial 1111)" && tail -26 $T/tg.log | grep -q "Kết quả: ĐÃ HOÀN TÁC: PBX và SBC đều phục vụ cert cũ" && [ "$(openssl s_client -connect 127.0.0.1:18883 </dev/null 2>/dev/null | openssl x509 -noout -serial | cut -d= -f2)" = 1111 ]'
check "S37 lệnh now ghi rõ chạy tay không tính vào giới hạn" 'tail -26 $T/tg.log | grep -q "Chạy tay (không tính vào giới hạn lần thử)" && tail -26 $T/tg.log | grep -q "Cert vẫn CHỜ ÁP DỤNG"'


echo "== S38 mốc hoàn tác được ghi lại cả khi SBC vốn đã đúng và chỉ PBX đổi; cảnh báo PBX_PORTS rỗng"
win_open; reset_old; rm -rf $T/state/applied
$T/stubs/srv.sh start sbc 18883 $T/state/staged/chain.pem $T/state/staged/key.pem
echo "serial=$(cat $T/state/staged/serial)" > $T/state/pending; rm -f $T/state/attempts-*
$DEP now >/dev/null; rc=$?
check "S38 thành công khi chỉ PBX cần đổi, không gọi API SBC" '[ $rc = 0 ] && [ ! -e $T/curl.log ]'
check "S38 mốc hoàn tác (applied/) được ghi bằng cert vừa áp dụng" '[ "$(cat $T/state/applied/serial 2>/dev/null)" = "$(cat $T/state/staged/serial)" ]'
cp $T/cfg/config.conf $T/cfg/config.conf.keep10; printf 'PBX_PORTS=""\n' >> $T/cfg/config.conf
out=$($DEP status 2>&1); check "S38 status cảnh báo PBX_PORTS rỗng" 'echo "$out" | grep -q "CẢNH BÁO: PBX_PORTS rỗng"'
cp $T/cfg/config.conf.keep10 $T/cfg/config.conf

$T/stubs/srv.sh stop pbx; $T/stubs/srv.sh stop sbc

echo; echo "KẾT QUẢ: $ok đạt, $bad lỗi"
$T/stubs/srv.sh stop pbx; $T/stubs/srv.sh stop sbc
