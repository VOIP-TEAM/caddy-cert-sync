#!/bin/bash
# tests/test-container.sh — kiểm thử bộ lập lịch của container (container/entrypoint.sh) và health-check không systemd.
# KHÔNG cần Docker: chạy entrypoint trực tiếp với đồng hồ giả và các script giả.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d /tmp/ctr-test.XXXXXX)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
ok=0; bad=0
check() { if eval "$2"; then echo "  OK   $1"; ok=$((ok+1)); else echo "  FAIL $1"; bad=$((bad+1)); fi; }
mkdir -p "$T/cfg" "$T/bin" "$T/state"
cat > "$T/cfg/config.conf" << C
DOMAIN="sip.test"
WINDOW_START=22
WINDOW_END=5
STATE_DIR="$T/state"
LOG="$T/log"
C
printf 'notify_telegram() { printf "%%s\\n----\\n" "$1" >> "$TGLOG"; }\n' > "$T/bin/lib-notify.sh"
printf '#!/bin/bash\necho "$1 $(cat "$CLOCKFILE")" >> "$CALLS"\nexit "${STUB_RC:-0}"\n' > "$T/bin/cert-deploy.sh"
printf '#!/bin/bash\necho $$ >> "$WPIDS"\nexec sleep 600\n' > "$T/bin/watch-caddy-cert.sh"
chmod +x "$T/bin/cert-deploy.sh" "$T/bin/watch-caddy-cert.sh"
export CFG_DIR="$T/cfg" BIN_DIR="$T/bin" SCHED_TICK=0.2 CLOCKFILE="$T/clock" CALLS="$T/calls" WPIDS="$T/wpids" TGLOG="$T/tg.log"
export SCHED_NOW_CMD='cat "$CLOCKFILE"'
echo "2026-10-20 12 00" > "$CLOCKFILE"
setclock() { echo "$1" > "$CLOCKFILE"; sleep 1.5; }       # 0,9 giây = hơn 4 vòng lặp: kiểm tra "chỉ một lần mỗi mốc"
n() { local c; c=$(grep -c "^$1 " "$CALLS" 2>/dev/null); echo "${c:-0}"; }

echo "== C1 bộ lập lịch"
bash "$ROOT/container/entrypoint.sh" > "$T/out" 2>&1 & EP=$!
sleep 2        # đủ cho khởi động và vòng lặp đầu tiên
check "12:00 ngoài khung giờ: không apply, stuck đúng một lần" '[ "$(n apply)" = 0 ] && [ "$(n stuck)" = 1 ]'
setclock "2026-10-20 22 00"
check "22:00 trong khung giờ: apply một lần và stuck một lần (dù có nhiều vòng lặp)" '[ "$(n apply)" = 1 ] && [ "$(n stuck)" = 2 ]'
setclock "2026-10-20 22 07"
check "22:07 không phải mốc 15 phút: không gọi gì thêm" '[ "$(n apply)" = 1 ] && [ "$(n stuck)" = 2 ]'
setclock "2026-10-20 22 15"; setclock "2026-10-20 22 30"
check "22:15 và 22:30: mỗi mốc một lần apply, không gọi stuck" '[ "$(n apply)" = 3 ] && [ "$(n stuck)" = 2 ]'
setclock "2026-10-21 03 45"
check "03:45 (khung vắt qua nửa đêm): apply" '[ "$(n apply)" = 4 ]'
setclock "2026-10-21 05 00"
check "05:00 hết khung giờ: không apply, vẫn stuck (mỗi giờ)" '[ "$(n apply)" = 4 ] && [ "$(n stuck)" = 3 ]'
setclock "2026-10-21 05 15"; setclock "2026-10-21 21 45"
check "05:15 và 21:45 ngoài khung giờ: không apply" '[ "$(n apply)" = 4 ]'
setclock "2026-10-21 22 00"
check "22:00 ngày hôm sau: apply lại (mốc mới, ngày mới)" '[ "$(n apply)" = 5 ] && [ "$(n stuck)" = 4 ]'
check "mỗi lần gọi đúng thời điểm (ghi kèm giờ giả)" 'grep -q "^apply 2026-10-20 22 15$" "$CALLS" && grep -q "^apply 2026-10-21 03 45$" "$CALLS"'
check "cho tới giờ này chưa gọi expiry lần nào (chỉ gọi lúc 09:00)" '[ "$(n expiry)" = 0 ]'
setclock "2026-10-22 09 00"; setclock "2026-10-22 09 15"
check "09:00: gọi expiry đúng một lần (09:15 không gọi lại), vẫn gọi stuck theo giờ" '[ "$(n expiry)" = 1 ] && [ "$(n stuck)" = 5 ]'

echo "== C2 giữ watcher sống"
check "watcher được khởi động một lần" '[ "$(wc -l < "$WPIDS")" = 1 ]'
W1=$(tail -1 "$WPIDS"); kill "$W1"; sleep 3.5
check "watcher bị giết: được khởi động lại bằng tiến trình mới" '[ "$(wc -l < "$WPIDS")" = 2 ] && [ "$(tail -1 "$WPIDS")" != "$W1" ] && kill -0 "$(tail -1 "$WPIDS")" 2>/dev/null'
check "ghi log và gửi Telegram khi watcher dừng" 'grep -q "LỖI: watcher dừng" "$T/log" && grep -q "watcher trong container đã dừng" "$TGLOG"'

echo "== C3 tắt êm"
W2=$(tail -1 "$WPIDS"); kill -TERM "$EP"; sleep 1.5
check "nhận SIGTERM: entrypoint thoát" '! kill -0 "$EP" 2>/dev/null'
check "watcher con cũng bị dừng, không để lại tiến trình mồ côi" '! kill -0 "$W2" 2>/dev/null'

echo "== C4 thiếu cấu hình"
CFG_DIR="$T/khong-co" bash "$ROOT/container/entrypoint.sh" > "$T/out2" 2>&1; rc=$?
check "không có config.conf: thoát mã 1 và nói rõ nguyên nhân" '[ $rc = 1 ] && grep -q "Không đọc được" "$T/out2"'

echo "== C5 health-check ở hai chế độ"
mkdir -p "$T/hc/state" "$T/stubs"
printf 'DOMAIN="x"\nCADDY_CERT_BASE="%s/none"\nSTATE_DIR="%s/hc/state"\nLOG="%s/hc/log"\n' "$T" "$T" "$T" > "$T/hc/config.conf"
printf '#!/bin/bash\ncase "$1 $2" in "is-active caddy-cert-sync") echo inactive; exit 3;; "is-enabled "*) echo enabled;; "is-active "*) echo active;; esac\n' > "$T/stubs/systemctl"; chmod +x "$T/stubs/systemctl"
out=$(CFG_DIR="$T/hc" SYSTEMD_RUN_DIR="$T/khong-co-systemd" bash "$ROOT/bin/health-check.sh" 2>&1)
check "không có systemd: bỏ qua kiểm tra dịch vụ, không báo lỗi giả" 'echo "$out" | grep -q "không có systemd" && ! echo "$out" | grep -q "caddy-cert-sync không chạy" && ! echo "$out" | grep -q "caddy-cert-apply.timer"'
out=$(PATH="$T/stubs:$PATH" CFG_DIR="$T/hc" SYSTEMD_RUN_DIR="$T" bash "$ROOT/bin/health-check.sh" 2>&1)
check "có systemd: vẫn kiểm tra như cũ (dịch vụ dừng bị báo lỗi)" 'echo "$out" | grep -q "caddy-cert-sync không chạy" && echo "$out" | grep -q "caddy-cert-apply.timer active, enabled"'

echo; echo "KẾT QUẢ: $ok đạt, $bad lỗi"
[ "$bad" -eq 0 ]
