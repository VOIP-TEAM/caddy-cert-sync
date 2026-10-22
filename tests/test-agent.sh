#!/bin/bash
# tests/test-agent.sh — kiểm thử bin/pbx-agent.sh (chạy trên VM PBX): ghi nguyên tử, sao lưu, hoàn tác, chống chèn lệnh. Không cần PortSIP.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d /tmp/agent-test.XXXXXX)
trap 'rm -rf "$T" /tmp/agent-pwn-1 /tmp/agent-pwn-2 /tmp/agent-pwn-3' EXIT
ok=0; bad=0
check() { if eval "$2"; then echo "  OK   $1"; ok=$((ok+1)); else echo "  FAIL $1"; bad=$((bad+1)); fi; }
mkdir -p "$T/vm/certs" "$T/stubs" "$T/c"
cd "$T/c" || exit 1
mk() { openssl ecparam -name prime256v1 -genkey -noout -out "$1.key" 2>/dev/null
       openssl req -x509 -new -key "$1.key" -subj "/CN=$1" -days 30 -set_serial "$2" -out "$1.crt" 2>/dev/null; }
mk old 0x11; mk new 0x22; mk other 0x33
cat > "$T/agent.conf" << C
PBX_CRT="$T/vm/certs/portsip.crt"
PBX_KEY="$T/vm/certs/portsip.key"
PORTSIP_UID=$(id -u)
PORTSIP_GID=$(id -g)
PBX_RESTART_CONTAINERS="portsip.webserver portsip.other"
C
printf '#!/bin/bash\necho "docker $*" >> "%s/docker.log"\n[ -f "%s/docker.fail" ] && { echo "Error: No such container" >&2; exit 1; }\nexit 0\n' "$T" "$T" > "$T/stubs/docker"; chmod +x "$T/stubs/docker"
export PATH="$T/stubs:$PATH" AGENT_CONF="$T/agent.conf" AGENT_LOCK="$T/lock" AGENT_LOG="$T/agent.log"
A="bash $ROOT/bin/pbx-agent.sh"
CRT="$T/vm/certs/portsip.crt"; KEY="$T/vm/certs/portsip.key"
ser() { openssl x509 -noout -serial -in "$1" | cut -d= -f2; }
put_pair() { $A put crt < "$1.crt" >/dev/null 2>&1; $A put key < "$1.key" >/dev/null 2>&1; }

echo "== G1 ping và lệnh không hợp lệ"
out=$($A ping 2>&1); check "ping trả lời" '[ "$out" = "pbx-agent ok" ]'
$A foo >/dev/null 2>&1; check "lệnh lạ bị từ chối (mã 2)" '[ $? = 2 ]'
$A >/dev/null 2>&1; check "không có lệnh bị từ chối (mã 2)" '[ $? = 2 ]'
$A put foo >/dev/null 2>&1; check "put với đối số lạ bị từ chối (mã 2)" '[ $? = 2 ]'

echo "== G2 cài lần đầu (chưa có file)"
out=$($A put crt < old.crt 2>&1)
check "put in sha256 đúng của nội dung đã gửi" '[ "${out##* }" = "$(sha256sum < old.crt | cut -d" " -f1)" ]'
check "put chưa đụng file đích, chỉ ghi .new" '[ ! -e "$CRT" ] && [ -s "$CRT.new" ]'
$A put key < old.key >/dev/null 2>&1
out=$($A commit 2>&1); rc=$?
check "commit thành công" '[ $rc = 0 ] && [ "$out" = ok ]'
check "file đích có đúng cert, quyền 600, không còn .new" '[ "$(ser "$CRT")" = "$(ser old.crt)" ] && [ "$(stat -c %a "$CRT")" = 600 ] && [ "$(stat -c %a "$KEY")" = 600 ] && [ ! -e "$CRT.new" ] && [ ! -e "$KEY.new" ]'
check "lần đầu không có .prev" '[ ! -e "$CRT.prev" ] && [ ! -e "$KEY.prev" ]'

echo "== G3 thay cert đã có: sao lưu, giữ quyền"
chmod 640 "$CRT" "$KEY"
put_pair new; before_old=$(ser "$CRT")
check "put không làm đổi file đang chạy" '[ "$(ser "$CRT")" = "$before_old" ] && [ "$(ser "$CRT")" = "$(ser old.crt)" ]'
$A commit >/dev/null 2>&1; rc=$?
check "commit thành công, file đích là cert mới" '[ $rc = 0 ] && [ "$(ser "$CRT")" = "$(ser new.crt)" ]'
check "bản cũ được sao lưu thành .prev" '[ "$(ser "$CRT.prev")" = "$(ser old.crt)" ] && cmp -s "$KEY.prev" old.key'
check "quyền của file cũ (640) được giữ cho file mới" '[ "$(stat -c %a "$CRT")" = 640 ] && [ "$(stat -c %a "$KEY")" = 640 ]'

echo "== G4 hoàn tác"
out=$($A rollback 2>&1); rc=$?
check "rollback khôi phục cert và khoá cũ" '[ $rc = 0 ] && [ "$(ser "$CRT")" = "$(ser old.crt)" ] && cmp -s "$KEY" old.key'
check ".prev đã được dùng, không còn" '[ ! -e "$CRT.prev" ] && [ ! -e "$KEY.prev" ]'
$A rollback >/dev/null 2>&1; check "rollback lần hai: mã 3 (không có bản cũ), không phá file" '[ $? = 3 ] && [ "$(ser "$CRT")" = "$(ser old.crt)" ]'

echo "== G5 cặp mới không hợp lệ thì không đụng file đang chạy"
$A put crt < new.crt >/dev/null 2>&1; $A put key < other.key >/dev/null 2>&1
out=$($A commit 2>&1); rc=$?
check "khoá không khớp cert: commit từ chối, nêu lý do" '[ $rc != 0 ] && echo "$out" | grep -q "không khớp"'
check "file đang chạy còn nguyên" '[ "$(ser "$CRT")" = "$(ser old.crt)" ] && cmp -s "$KEY" old.key'
$A abort >/dev/null 2>&1; check "abort xoá file tạm" '[ ! -e "$CRT.new" ] && [ ! -e "$KEY.new" ]'
$A commit >/dev/null 2>&1; check "commit khi chưa put: từ chối" '[ $? != 0 ] && [ "$(ser "$CRT")" = "$(ser old.crt)" ]'
printf 'khong phai cert\n' | $A put crt >/dev/null 2>&1; $A put key < new.key >/dev/null 2>&1
$A commit >/dev/null 2>&1; check "cert không đọc được: commit từ chối, file đang chạy còn nguyên" '[ $? != 0 ] && [ "$(ser "$CRT")" = "$(ser old.crt)" ]'
$A abort >/dev/null 2>&1
: | $A put crt >/dev/null 2>&1; rc=$?
check "put với nội dung rỗng bị từ chối và không để lại .new" '[ $rc != 0 ] && [ ! -e "$CRT.new" ]'

echo "== G6 .prev cũ không bị dùng nhầm"
rm -f "$CRT" "$KEY"; echo "ban-cu-sai" > "$CRT.prev"; echo "ban-cu-sai" > "$KEY.prev"
put_pair new; $A commit >/dev/null 2>&1
check "chưa có file hiện tại: .prev tồn đọng bị xoá khi commit" '[ ! -e "$CRT.prev" ] && [ ! -e "$KEY.prev" ] && [ "$(ser "$CRT")" = "$(ser new.crt)" ]'
$A rollback >/dev/null 2>&1; check "vì vậy rollback sau lần cài đầu không khôi phục bản sai (mã 3)" '[ $? = 3 ] && [ "$(ser "$CRT")" = "$(ser new.crt)" ]'

echo "== G7 restart"
rm -f "$T/docker.log"; $A restart >/dev/null 2>&1; rc=$?
check "restart gọi docker restart -t 300 với đúng các container trong cấu hình" '[ $rc = 0 ] && grep -q "restart -t 300 portsip.webserver portsip.other" "$T/docker.log"'
touch "$T/docker.fail"; out=$($A restart 2>&1); rc=$?
check "docker lỗi: trả mã khác 0 và kèm lỗi gốc" '[ $rc != 0 ] && echo "$out" | grep -q "No such container"'
rm -f "$T/docker.fail"

echo "== G8 chạy qua SSH (SSH_ORIGINAL_COMMAND): chỉ nhận lệnh trong danh sách, không chèn lệnh, không tin biến môi trường"
sshrun() { SSH_ORIGINAL_COMMAND="$1" bash "$ROOT/bin/pbx-agent.sh"; }
out=$(sshrun "ping" 2>&1); check "ping qua SSH" '[ "$out" = "pbx-agent ok" ]'
sshrun "ping; touch /tmp/agent-pwn-1" >/dev/null 2>&1; check "nối thêm lệnh sau dấu ; bị từ chối, không chạy" '[ $? = 2 ] && [ ! -e /tmp/agent-pwn-1 ]'
sshrun 'ping $(touch /tmp/agent-pwn-2)' >/dev/null 2>&1; check "chèn \$(...) vào đối số không được thực thi" '[ ! -e /tmp/agent-pwn-2 ]'
sshrun 'put crt;touch /tmp/agent-pwn-3' < old.crt >/dev/null 2>&1; check "put với đối số có ; bị từ chối, không chạy" '[ $? = 2 ] && [ ! -e /tmp/agent-pwn-3 ]'
sshrun "bash -c id" >/dev/null 2>&1; check "xin chạy shell bị từ chối (mã 2)" '[ $? = 2 ]'
mkdir -p "$T/evil"; rm -f "$CRT" "$KEY"
SSH_ORIGINAL_COMMAND="put crt" PBX_CRT="$T/evil/x.crt" PBX_KEY="$T/evil/x.key" bash "$ROOT/bin/pbx-agent.sh" < new.crt >/dev/null 2>&1
SSH_ORIGINAL_COMMAND="put key" PBX_CRT="$T/evil/x.crt" PBX_KEY="$T/evil/x.key" bash "$ROOT/bin/pbx-agent.sh" < new.key >/dev/null 2>&1
SSH_ORIGINAL_COMMAND="commit" PBX_CRT="$T/evil/x.crt" PBX_KEY="$T/evil/x.key" bash "$ROOT/bin/pbx-agent.sh" >/dev/null 2>&1
check "qua SSH: biến môi trường PBX_CRT/PBX_KEY bị bỏ qua, file đi vào đường dẫn trong cấu hình" '[ -s "$CRT" ] && [ -s "$KEY" ] && [ -z "$(ls -A "$T/evil")" ]'

echo; echo "KẾT QUẢ: $ok đạt, $bad lỗi"
[ "$bad" -eq 0 ]
