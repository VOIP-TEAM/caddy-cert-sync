# Lịch sử thay đổi

## 1.5.0
Tách phương án build theo trường hợp triển khai:
- Cùng VM: gói caddy-cert-sync (đầy đủ). Khác VM: VM SBC cài gói caddy-cert-sync, VM PBX cài gói caddy-cert-sync-agent (chỉ có pbx-agent.sh).
- make release dựng tất cả: tarball mã nguồn, tarball agent, hai gói deb và SHA256SUMS. Thêm make dist-agent, make deb-agent, make sums.
- Gói deb nén xz (trước đây zstd, dpkg cũ trên Ubuntu 20.04 có thể không đọc được).
- Gói đầy đủ kèm hồ sơ same-vm và diff-vm trong /usr/local/share/caddy-cert-sync/profiles/ (không kèm hồ sơ riêng của từng server). Hai gói khai báo Conflicts với nhau để không cài chung một VM.
- tests/test-packaging.sh kiểm tra nội dung và metadata của từng sản phẩm.
- release.yml từ chối tag không nằm trên nhánh main.
- tests/run-tests.sh thoát mã 1 khi có điểm lỗi (trước đó luôn thoát 0 nên CI không đỏ khi bộ kiểm thử chính lỗi; chỉ các bộ khác làm CI đỏ).
- ci.yml và release.yml kiểm tra ngay từ đầu rằng script có quyền thực thi trong Git (mode 100755), vì Git trên Windows ghi quyền 644.
- Thêm .gitattributes ép xuống dòng LF cho mọi tệp văn bản.
- tests/test-container.sh bớt chập chờn (chờ lâu hơn giữa các mốc giờ giả). Các bộ kiểm thử đã được chạy bằng người dùng thường, như runner của GitHub.

## 1.4.0
Đổi logic thay cert theo yêu cầu vận hành:
- Chỉ thay khi có cert chờ áp dụng. Không còn tự áp dụng lại khi cổng lệch cert: chỉ báo Telegram (kiểm tra mỗi giờ). `now` cũng cần cert chờ; `now --force` để ép.
- Một bên lỗi thì hoàn tác cả hai về cert cũ (PBX lỗi: bỏ qua SBC; SBC lỗi: hoàn tác SBC rồi PBX). Đã bỏ các tuỳ chọn SYNC_MODE và PBX_ROLLBACK.
- Hoàn tác SBC có xác minh serial; không có mốc hoàn tác hoặc không xác minh được thì báo CẦN KIỂM TRA TAY và dừng tự thử lại.
- Tin [2/2] ghi serial trước và sau, lần thử n/N, kết quả hoàn tác và bước tiếp theo.
- Lệnh `baseline CRT KEY` ghi mốc hoàn tác cho SBC trước lần thay đầu. Mốc hoàn tác cũng được ghi sau mỗi lần thay thành công.
- Cảnh báo khi PBX_PORTS rỗng (status và health-check).
- Hồ sơ same-vm (cùng VM) và diff-vm (khác VM, hệ thống trên VM SBC); bỏ two-vm-paste và pbx-remote.
- Tài liệu viết lại thành bốn phần: sơ đồ thiết kế, lý do, thành phần, cài đặt.

## 1.3.0
PBX ở VM khác VM chạy hệ thống: thay cert PBX qua SSH tới agent (bin/pbx-agent.sh, bin/lib-remote.sh), cài agent bằng install.sh --agent.
Khoá SSH bị ràng buộc bằng command=, agent chỉ nhận các lệnh ping, put, commit, restart, rollback, abort.
Thay file PBX nguyên tử (ghi .new, đối chiếu sha256, kiểm tra khoá khớp cert, sao lưu .prev, đổi tên), và hoàn tác khi restart hoặc xác minh lỗi (PBX_ROLLBACK).
SYNC_MODE: loose (mặc định) hoặc strict (PBX lỗi thì bỏ qua SBC; SBC lỗi thì đưa PBX về cert cũ). Cũng áp dụng khi PBX ở cùng máy: PBX giờ cũng ghi nguyên tử và có hoàn tác.
Hồ sơ pbx-remote. Bài kiểm thử: bộ chính thêm 8 tình huống PBX ở VM khác, tests/test-agent.sh, tests/test-ssh-real.sh (sshd thật). Chưa thử với VM thật.

## 1.2.0
Hỗ trợ PBX và SBC ở hai VM riêng: mục cổng dạng host:port, SNI riêng cho PBX và SBC (PBX_SNI, SBC_SNI),
SBC_DOCKER_CMD (none hoặc ssh) cho restart dự phòng, health-check khớp theo.
paste-cert.sh để dán cert thủ công trên VM PBX, hồ sơ two-vm-paste.
cert-deploy.sh expiry và timer caddy-cert-expiry-check: nhắc khi cert đang dùng sắp hết hạn (EXPIRY_ALERT_DAYS).
Bài kiểm thử: bộ chính thêm tình huống SBC ở máy khác và nhắc hết hạn, thêm tests/test-two-vm.sh. Chưa thử với hai VM thật.

## 1.1.0
Thêm cách chạy bằng container (container/): Dockerfile, bộ lập lịch thay systemd, compose.example.yml, workflow đẩy image lên GHCR.
health-check.sh tự bỏ qua kiểm tra systemd khi không có systemd. Image chưa được dựng và chạy thử với Docker thật.

## 1.0.0
Bản đầu tiên đưa lên Git. Gồm: watcher canh cert, chuẩn bị rồi áp dụng trong khung giờ, dấu CHỜ ÁP DỤNG,
thay cert PBX (restart portsip.webserver) và SBC (qua API), đo cổng để xác minh, hoàn tác SBC,
giới hạn số lần thử, khoá chống chạy chồng, cảnh báo Telegram, health-check, tls-scan,
set-renew-days, renew-status, tuỳ chọn hoãn thay (DEPLOY_WHEN_DAYS_LEFT), hỗ trợ lego (mục 5.11).
Bài kiểm thử: 88 điểm trong môi trường giả lập.
