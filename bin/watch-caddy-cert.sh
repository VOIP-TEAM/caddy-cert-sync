#!/bin/bash
# Theo dõi thư mục cert của Caddy (đệ quy, mọi nhà cấp). Mỗi sự kiện, và mỗi giờ khi không có sự kiện,
# chạy "cert-deploy.sh stage". Chạy bù hằng giờ giúp phục hồi nếu thư mục bị xoá và tạo lại (đổi inode).
source "${CFG_DIR:-/etc/caddy-cert-sync}/config.conf"
DEPLOY="${LIB_DIR:-/usr/local/bin}/cert-deploy.sh"
WATCH="$CADDY_CERT_BASE/certificates"

while true; do
    if [ ! -d "$WATCH" ]; then sleep 10; continue; fi
    inotifywait -r -q -t "${WATCH_TIMEOUT:-3600}" -e close_write,create,moved_to "$WATCH" >/dev/null 2>&1
    rc=$?
    # 0 = có sự kiện (đợi Caddy ghi xong cả crt và key)
    # 2 = hết giờ chờ (chạy bù)
    # khác = mất watch, thường do thư mục bị xoá và tạo lại: nghỉ rồi chạy bù ngay để không sót cert
    if   [ "$rc" -eq 0 ]; then sleep 5
    elif [ "$rc" -ne 2 ]; then sleep 10
    fi
    "$DEPLOY" stage; stage_rc=$?         # lưu mã thoát trước: $(date) bên dưới sẽ đặt lại $? về 0
    [ "$stage_rc" -eq 0 ] || echo "$(date '+%F %T') - LỖI: cert-deploy.sh stage thoát với mã $stage_rc" >> "$LOG"
done
