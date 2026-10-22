#!/bin/bash
# tests/test-ssh-real.sh — chạy một sshd THẬT ở cổng riêng để kiểm tra pbx_agent qua SSH thật:
# khoá bị ràng buộc bằng command=, dữ liệu cert đi nguyên vẹn qua stdin, kiểm tra khoá máy chủ, giới hạn from=.
# Bỏ qua nếu máy không có sshd. Không cần quyền root, không ghi ra ngoài thư mục tạm.
SSHD=$(command -v sshd || ls /usr/sbin/sshd 2>/dev/null | head -1)
[ -x "${SSHD:-}" ] && command -v ssh-keygen >/dev/null || { echo "Không có sshd hoặc ssh-keygen: bỏ qua bài kiểm thử SSH thật"; exit 0; }
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d /tmp/sshreal.XXXXXX); chmod 755 "$T"
trap 'kill $(cat "$T/sshd.pid" 2>/dev/null) 2>/dev/null; rm -rf "$T"' EXIT
ok=0; bad=0
check() { if eval "$2"; then echo "  OK   $1"; ok=$((ok+1)); else echo "  FAIL $1"; bad=$((bad+1)); fi; }
PORT=$(( 20000 + RANDOM % 20000 ))
mkdir -p "$T/vm/certs" "$T/stubs" "$T/c"; cd "$T/c" || exit 1
ssh-keygen -q -t ed25519 -N "" -f "$T/host" ; ssh-keygen -q -t ed25519 -N "" -f "$T/client"; ssh-keygen -q -t ed25519 -N "" -f "$T/other"
printf 'restrict,command="%s/bin/pbx-agent.sh" %s\n' "$ROOT" "$(cat "$T/client.pub")" > "$T/authorized_keys"
printf 'restrict,command="%s/bin/pbx-agent.sh",from="10.9.9.9" %s\n' "$ROOT" "$(cat "$T/other.pub")" >> "$T/authorized_keys"
printf '#!/bin/bash\necho "docker $*" >> "%s/docker.log"\nexit 0\n' "$T" > "$T/stubs/docker"; chmod +x "$T/stubs/docker"
cat > "$T/agent.conf" << C
PBX_CRT="$T/vm/certs/portsip.crt"
PBX_KEY="$T/vm/certs/portsip.key"
PORTSIP_UID=$(id -u)
PORTSIP_GID=$(id -g)
PBX_RESTART_CONTAINERS="portsip.webserver"
C
cat > "$T/sshd_config" << C
Port $PORT
ListenAddress 127.0.0.1
HostKey $T/host
AuthorizedKeysFile $T/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PidFile $T/sshd.pid
LogLevel ERROR
PermitRootLogin forced-commands-only
SetEnv AGENT_CONF=$T/agent.conf AGENT_LOCK=$T/lock AGENT_LOG=$T/agent.log PATH=$T/stubs:/usr/local/bin:/usr/bin:/bin
C
$SSHD -f "$T/sshd_config" 2>"$T/sshd.err" || { echo "Không khởi động được sshd: $(head -2 "$T/sshd.err")"; exit 0; }
for _ in $(seq 1 20); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.3; done
ssh-keyscan -p "$PORT" -t ed25519 127.0.0.1 2>/dev/null > "$T/known_hosts"
export PBX_SSH="$(id -un)@127.0.0.1" PBX_SSH_KEY="$T/client"
export PBX_SSH_OPTS="-p $PORT -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$T/known_hosts"
export LIB_DIR="$ROOT/bin"
# shellcheck disable=SC1091
source "$ROOT/bin/lib-remote.sh"
ser() { openssl x509 -noout -serial -in "$1" | cut -d= -f2; }
mk() { openssl ecparam -name prime256v1 -genkey -noout -out "$1.key" 2>/dev/null; openssl req -x509 -new -key "$1.key" -subj "/CN=$1" -days 30 -set_serial "$2" -out "$1.crt" 2>/dev/null; }
mk old 0x11; mk new 0x22
# chuỗi dài hơn nhiều so với thực tế để thử việc truyền qua stdin
cat new.crt > big.crt; for _ in $(seq 1 200); do cat old.crt >> big.crt; done

echo "== R1 qua SSH thật, khoá bị ràng buộc bằng command="
out=$(pbx_agent ping 2>&1); check "ping qua SSH thật" '[ "$out" = "pbx-agent ok" ]'
out=$(pbx_agent "bash -c id" 2>&1); rc=$?
check "xin chạy shell bị agent từ chối (mã 2), không có shell" '[ $rc = 2 ] && echo "$out" | grep -q "lệnh không hợp lệ" && ! echo "$out" | grep -q "uid="'
out=$(ssh $PBX_SSH_OPTS -i "$T/client" "$PBX_SSH" 2>&1 < /dev/null); rc=$?
check "đăng nhập không kèm lệnh cũng chỉ chạm agent (không vào shell)" '[ $rc = 2 ] && echo "$out" | grep -q "lệnh không hợp lệ"'
out=$(pbx_agent "ping; touch $T/pwned" 2>&1); check "nối thêm lệnh qua SSH không được thực thi" '[ ! -e "$T/pwned" ]'

echo "== R2 chuỗi thay cert đầy đủ qua SSH thật"
out=$(pbx_agent put crt < new.crt 2>&1); check "put crt: sha256 do VM PBX tính khớp bản gốc" '[ "${out##* }" = "$(sha256sum < new.crt | cut -d" " -f1)" ]'
out=$(pbx_agent put key < new.key 2>&1); check "put key: sha256 khớp" '[ "${out##* }" = "$(sha256sum < new.key | cut -d" " -f1)" ]'
out=$(pbx_agent commit 2>&1); check "commit thành công và file nằm đúng chỗ" '[ "$out" = ok ] && [ "$(ser "$T/vm/certs/portsip.crt")" = "$(ser new.crt)" ]'
out=$(pbx_agent put crt < big.crt 2>&1); check "nội dung lớn (khoảng $(wc -c < big.crt) byte) qua stdin không bị mất byte nào" '[ "${out##* }" = "$(sha256sum < big.crt | cut -d" " -f1)" ]'
pbx_agent abort >/dev/null 2>&1
out=$(pbx_agent restart 2>&1); check "restart chạy docker trên VM PBX" '[ $? = 0 ] && grep -q "restart -t 300 portsip.webserver" "$T/docker.log"'
mk newer 0x44; pbx_agent put crt < newer.crt >/dev/null 2>&1; pbx_agent put key < newer.key >/dev/null 2>&1; pbx_agent commit >/dev/null 2>&1
out=$(pbx_agent rollback 2>&1); check "hoàn tác qua SSH khôi phục cert trước" '[ "$out" = ok ] && [ "$(ser "$T/vm/certs/portsip.crt")" = "$(ser new.crt)" ]'

echo "== R3 kiểm tra khoá máy chủ và giới hạn nguồn"
cp "$T/known_hosts" "$T/known_hosts.good"
ssh-keygen -q -t ed25519 -N "" -f "$T/fakehost"; printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1,2 "$T/fakehost.pub")" > "$T/known_hosts"
out=$(pbx_agent ping 2>&1); rc=$?
check "khoá máy chủ khác với known_hosts (giả mạo VM PBX): từ chối, mã 255, không chạy lệnh" '[ $rc = 255 ] && echo "$out" | grep -qi "host key verification failed\|REMOTE HOST IDENTIFICATION"'
: > "$T/known_hosts"; out=$(pbx_agent ping 2>&1); rc=$?
check "chưa biết máy chủ (known_hosts rỗng) và StrictHostKeyChecking=yes: từ chối, không tin lần đầu" '[ $rc = 255 ]'
cp "$T/known_hosts.good" "$T/known_hosts"
PBX_SSH_KEY="$T/other" pbx_agent ping >/dev/null 2>&1; check "khoá có from=\"10.9.9.9\" bị từ chối khi nối từ 127.0.0.1" '[ $? = 255 ]'
out=$(pbx_agent ping 2>&1); check "khôi phục known_hosts đúng thì nối lại được" '[ "$out" = "pbx-agent ok" ]'

echo; echo "KẾT QUẢ: $ok đạt, $bad lỗi"
[ "$bad" -eq 0 ]
