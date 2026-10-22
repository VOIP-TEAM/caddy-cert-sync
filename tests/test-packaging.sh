#!/bin/bash
# tests/test-packaging.sh — kiểm tra các sản phẩm build (make release): nội dung, quyền, metadata, checksum, và script cài đặt trong gói.
# Không cần root: dùng dpkg-deb, dpkg -x và thư mục gốc giả (DPKG_ROOT, DESTDIR).
command -v dpkg-deb >/dev/null && command -v make >/dev/null || { echo "Không có dpkg-deb hoặc make: bỏ qua bài kiểm thử đóng gói"; exit 0; }
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d /tmp/pkg-test.XXXXXX); trap 'rm -rf "$T"' EXIT
ok=0; bad=0
check() { if eval "$2"; then echo "  OK   $1"; ok=$((ok+1)); else echo "  FAIL $1"; bad=$((bad+1)); fi; }
V=$(cat "$ROOT/VERSION"); D="$T/dist"
make -C "$ROOT" DIST="$D" release >"$T/make.log" 2>&1; rc=$?
FULL="$D/caddy-cert-sync_${V}_all.deb"; AG="$D/caddy-cert-sync-agent_${V}_all.deb"
TF="$D/caddy-cert-sync-$V.tar.gz"; TA="$D/caddy-cert-sync-agent-$V.tar.gz"

echo "== K1 make release và checksum"
check "make release thành công và tạo đủ bốn sản phẩm cùng SHA256SUMS" '[ $rc = 0 ] && [ -f "$FULL" ] && [ -f "$AG" ] && [ -f "$TF" ] && [ -f "$TA" ] && [ -f "$D/SHA256SUMS" ]'
check "SHA256SUMS liệt kê đúng bốn tệp và sha256sum -c đạt" '[ "$(wc -l < "$D/SHA256SUMS")" = 4 ] && (cd "$D" && sha256sum -c SHA256SUMS >/dev/null 2>&1)'
cp -r "$D" "$T/d2"; printf 'x' >> "$T/d2/caddy-cert-sync-agent_${V}_all.deb"
check "sửa một byte của gói thì sha256sum -c báo lỗi (phát hiện hỏng hoặc bị thay)" '! (cd "$T/d2" && sha256sum -c SHA256SUMS >/dev/null 2>&1)'

echo "== K2 gói deb: định dạng và metadata"
check "nén xz (dpkg cũ trên Ubuntu 20.04 đọc được), không dùng zstd" 'ar t "$FULL" | grep -q "data.tar.xz" && ar t "$AG" | grep -q "data.tar.xz" && ! ar t "$FULL" "$AG" 2>/dev/null | grep -q zst'
check "số phiên bản trong hai gói khớp tệp VERSION" '[ "$(dpkg-deb -f "$FULL" Version)" = "$V" ] && [ "$(dpkg-deb -f "$AG" Version)" = "$V" ]'
check "hai gói khai báo xung đột với nhau (không cài chung một VM)" '[ "$(dpkg-deb -f "$FULL" Conflicts)" = "caddy-cert-sync-agent" ] && [ "$(dpkg-deb -f "$AG" Conflicts)" = "caddy-cert-sync" ]'
check "gói agent chỉ phụ thuộc thứ nó cần, không kéo jq, curl, inotify-tools" 'dpkg-deb -f "$AG" Depends | grep -q openssl && ! dpkg-deb -f "$AG" Depends | grep -qE "jq|curl|inotify"'
check "gói đầy đủ phụ thuộc openssl, curl, jq, inotify-tools" 'dpkg-deb -f "$FULL" Depends | grep -q openssl && dpkg-deb -f "$FULL" Depends | grep -q jq && dpkg-deb -f "$FULL" Depends | grep -q curl && dpkg-deb -f "$FULL" Depends | grep -q inotify-tools'

echo "== K3 nội dung từng sản phẩm"
dpkg-deb -c "$AG" | awk '{print $1, $6}' > "$T/ag.list"; dpkg-deb -c "$FULL" | awk '{print $1, $6}' > "$T/full.list"
check "gói agent chỉ chứa pbx-agent.sh, VERSION và mẫu cấu hình agent" '[ "$(grep -v "^d" "$T/ag.list" | wc -l)" = 3 ] && grep -q "^-rwxr-xr-x ./usr/local/bin/pbx-agent.sh$" "$T/ag.list" && grep -q "VERSION$" "$T/ag.list" && grep -q "pbx-cert-agent.conf.example$" "$T/ag.list"'
check "gói agent không có cert-deploy.sh, systemd, thông tin Telegram hay SBC" '! grep -qE "cert-deploy|systemd|telegram|sbc|watch-caddy" "$T/ag.list"'
check "gói đầy đủ có cert-deploy.sh, pbx-agent.sh (cho cùng VM) và đủ 5 dịch vụ cùng 4 timer" 'grep -q "bin/cert-deploy.sh$" "$T/full.list" && grep -q "bin/pbx-agent.sh$" "$T/full.list" && [ "$(grep -c "\.timer$" "$T/full.list")" = 4 ] && [ "$(grep -c "\.service$" "$T/full.list")" = 5 ]'
check "gói đầy đủ kèm hồ sơ same-vm và diff-vm, KHÔNG kèm hồ sơ riêng của server nào" 'grep -q "profiles/same-vm/config.conf$" "$T/full.list" && grep -q "profiles/diff-vm/config.conf$" "$T/full.list" && ! grep -qE "ecs-jqpd|_template" "$T/full.list"'
check "không gói nào chứa khoá riêng, cert hay tệp bí mật thật" '! grep -qE "\.(key|pem|crt)$|telegram\.conf$|sbc\.cred$" "$T/full.list" "$T/ag.list"'
check "quyền: script chạy 755, thư viện và cấu hình 644" 'grep -q "^-rwxr-xr-x ./usr/local/bin/cert-deploy.sh$" "$T/full.list" && grep -q "^-rw-r--r-- ./usr/local/bin/lib-live.sh$" "$T/full.list" && grep -q "^-rw-r--r-- ./usr/local/share/caddy-cert-sync/examples/config.conf.example$" "$T/full.list"'
dpkg-deb -x "$FULL" "$T/xfull"; dpkg-deb -x "$AG" "$T/xag"
check "mọi script trong gói đầy đủ qua kiểm tra cú pháp bash" 'for f in "$T"/xfull/usr/local/bin/*.sh; do bash -n "$f" || exit 1; done'
check "pbx-agent.sh trong gói agent, gói đầy đủ và mã nguồn là cùng một tệp" 'cmp -s "$T/xag/usr/local/bin/pbx-agent.sh" "$T/xfull/usr/local/bin/pbx-agent.sh" && cmp -s "$T/xag/usr/local/bin/pbx-agent.sh" "$ROOT/bin/pbx-agent.sh"'

echo "== K4 script cài đặt trong gói (thư mục gốc giả)"
dpkg-deb -e "$AG" "$T/cag"; dpkg-deb -e "$FULL" "$T/cfull"
R1="$T/root-agent"; mkdir -p "$R1"; cp -r "$T/xag/." "$R1/"
DPKG_ROOT="$R1" sh "$T/cag/postinst" configure >"$T/pa.out" 2>&1
check "postinst của gói agent tạo /etc/pbx-cert-agent.conf quyền 640 và hướng dẫn authorized_keys" '[ "$(stat -c %a "$R1/etc/pbx-cert-agent.conf")" = 640 ] && grep -q "restrict,command=" "$T/pa.out"'
echo "# sửa tay" >> "$R1/etc/pbx-cert-agent.conf"; DPKG_ROOT="$R1" sh "$T/cag/postinst" configure >"$T/pa2.out" 2>&1
check "chạy lại (nâng cấp): giữ nguyên cấu hình đã sửa tay" 'grep -q "sửa tay" "$R1/etc/pbx-cert-agent.conf" && grep -q "Giữ nguyên" "$T/pa2.out"'
R2="$T/root-full"; mkdir -p "$R2"; cp -r "$T/xfull/." "$R2/"
DPKG_ROOT="$R2" sh "$T/cfull/postinst" configure >/dev/null 2>&1
check "postinst của gói đầy đủ tạo config.conf (644), telegram.conf và sbc.cred (600)" '[ "$(stat -c %a "$R2/etc/caddy-cert-sync/config.conf")" = 644 ] && [ "$(stat -c %a "$R2/etc/caddy-cert-sync/telegram.conf")" = 600 ] && [ "$(stat -c %a "$R2/etc/caddy-cert-sync/sbc.cred")" = 600 ]'
echo 'DOMAIN="da-sua.example"' > "$R2/etc/caddy-cert-sync/config.conf"; DPKG_ROOT="$R2" sh "$T/cfull/postinst" configure >/dev/null 2>&1
check "chạy lại (nâng cấp): không ghi đè config.conf đã sửa" 'grep -q "da-sua.example" "$R2/etc/caddy-cert-sync/config.conf"'
mkdir -p "$T/vcfg"; printf 'DOMAIN="x"\nSTATE_DIR="%s/vstate"\nLOG="%s/vlog"\n' "$T" "$T" > "$T/vcfg/config.conf"
check "cert-deploy.sh trong gói đầy đủ báo đúng phiên bản" '[ "$(VERSION_FILE="$R2/usr/local/share/caddy-cert-sync/VERSION" CFG_DIR="$T/vcfg" LIB_DIR="$R2/usr/local/bin" bash "$R2/usr/local/bin/cert-deploy.sh" version 2>&1 | head -1)" = "$V" ]'

echo "== K5 tarball"
tar tzf "$TA" | sed "s#^caddy-cert-sync-agent-$V/##" | grep -v '^$' | grep -v '/$' | sort > "$T/ta.list"
check "tarball agent chỉ có install.sh, VERSION, bin/pbx-agent.sh, config/pbx-cert-agent.conf.example" '[ "$(tr "\n" " " < "$T/ta.list")" = "VERSION bin/pbx-agent.sh config/pbx-cert-agent.conf.example install.sh " ]'
mkdir -p "$T/ta" && tar xzf "$TA" -C "$T/ta"; DESTDIR="$T/fr" bash "$T/ta/caddy-cert-sync-agent-$V/install.sh" --agent >"$T/ia.out" 2>&1
check "install.sh --agent từ tarball agent cài đúng agent và cấu hình" '[ -x "$T/fr/usr/local/bin/pbx-agent.sh" ] && [ "$(stat -c %a "$T/fr/etc/pbx-cert-agent.conf")" = 640 ] && [ ! -e "$T/fr/usr/local/bin/cert-deploy.sh" ]'
out=$(DESTDIR="$T/fr2" bash "$T/ta/caddy-cert-sync-agent-$V/install.sh" --profile same-vm 2>&1); rc2=$?
check "cài đầy đủ từ tarball agent bị từ chối kèm lời chỉ dẫn" '[ $rc2 != 0 ] && echo "$out" | grep -q "chỉ có agent"'
tar tzf "$TF" | sed "s#^caddy-cert-sync-$V/##" > "$T/tf.list"
check "tarball mã nguồn có hồ sơ same-vm, diff-vm, workflow, Makefile" 'grep -q "^profiles/same-vm/config.conf$" "$T/tf.list" && grep -q "^profiles/diff-vm/config.conf$" "$T/tf.list" && grep -q "^.github/workflows/release.yml$" "$T/tf.list" && grep -q "^Makefile$" "$T/tf.list"'
check "tarball mã nguồn không chứa thư mục dist hay .git" '! grep -qE "^(dist|\.git)/" "$T/tf.list"'
mkdir -p "$T/tf" && tar xzf "$TF" -C "$T/tf"; DESTDIR="$T/fr3" bash "$T/tf/caddy-cert-sync-$V/install.sh" --profile diff-vm >/dev/null 2>&1
check "cài từ tarball mã nguồn với hồ sơ diff-vm: có cấu hình khác VM" 'grep -q "^PBX_SSH=" "$T/fr3/etc/caddy-cert-sync/config.conf"'

echo; echo "KẾT QUẢ: $ok đạt, $bad lỗi"
[ "$bad" -eq 0 ]
