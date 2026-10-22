# caddy-cert-sync

Tự động thay certificate cho PortSIP PBX và SBC: canh cert do Caddy (hoặc lego) cấp, chuẩn bị, rồi chỉ thay vào PortSIP
trong khung giờ bảo trì, thông báo qua Telegram. Tài liệu thiết kế đầy đủ nằm trong file Word đi kèm (Luong-tu-dong-thay-cert-PortSIP.docx).

## Cấu trúc repo

    bin/          chương trình: cert-deploy.sh (lõi), watch-caddy-cert.sh, health-check.sh, tls-scan.sh, ... và các lib-*.sh
    systemd/      dịch vụ và timer (optional/ là bản dùng lego)
    config/       bản mẫu config.conf, telegram.conf, sbc.cred (KHÔNG có giá trị thật)
    profiles/     cấu hình không bí mật theo từng server: profiles/<tên-server>/config.conf (có sẵn: same-vm, diff-vm, _template, ecs-jqpd)
    packaging/    file dựng gói .deb
    container/    Dockerfile, bộ lập lịch thay systemd, compose.example.yml (tuỳ chọn)
    tests/        bộ kiểm thử (môi trường giả lập, không cần PortSIP)
    patches/      bản vá Caddy tắt ARI (tuỳ chọn, mục 5.12 của tài liệu)
    VERSION       số phiên bản duy nhất; tag Git phải khớp (v + nội dung file này)

## Build: sản phẩm theo từng trường hợp

| Trường hợp | VM | Sản phẩm cần | Lệnh build |
|---|---|---|---|
| Cùng VM | VM duy nhất | `caddy-cert-sync_<bản>_all.deb` (hoặc tarball mã nguồn) | `make deb` |
| Khác VM | VM SBC (chạy hệ thống thay cert) | `caddy-cert-sync_<bản>_all.deb` | `make deb` |
| Khác VM | VM PBX (chỉ có agent) | `caddy-cert-sync-agent_<bản>_all.deb` (hoặc `caddy-cert-sync-agent-<bản>.tar.gz`) | `make deb-agent` hoặc `make dist-agent` |
| Mọi trường hợp | máy build | tất cả sản phẩm và `SHA256SUMS` | `make release` |

Hai gói deb khai báo `Conflicts` với nhau: không cài chung một VM. Gói đầy đủ kèm hồ sơ mẫu `same-vm` và `diff-vm` ở `/usr/local/share/caddy-cert-sync/profiles/`; hồ sơ riêng của từng server không bao giờ nằm trong gói. Hướng dẫn build đầy đủ nằm trong tài liệu `Huong-dan-build-he-thong-thay-cert-PortSIP.docx`.

## Cài trên một server

### Cách A: từ Git (hợp khi bạn quản lý nhiều server bằng hồ sơ)

    git clone <địa-chỉ-repo> && cd caddy-cert-sync
    git checkout v1.5.0                         # luôn cài từ tag, không cài từ nhánh
    sudo ./install.sh --profile ten-server      # lấy cấu hình từ profiles/ten-server/config.conf nếu server chưa có
    sudo nano /etc/caddy-cert-sync/telegram.conf /etc/caddy-cert-sync/sbc.cred    # điền giá trị thật
    sudo cert-deploy.sh status                  # kiểm tra, chưa đụng PBX/SBC
    sudo ./install.sh --enable                  # bật dịch vụ và timer

### Cách B: từ gói phát hành (.deb)

    curl -LO https://github.com/<tổ-chức>/<repo>/releases/download/v1.5.0/caddy-cert-sync_1.5.0_all.deb
    curl -LO https://github.com/<tổ-chức>/<repo>/releases/download/v1.5.0/SHA256SUMS
    sha256sum -c SHA256SUMS --ignore-missing    # phải in OK
    sudo dpkg -i caddy-cert-sync_1.5.0_all.deb          # VM PBX khi khác VM: tải và cài caddy-cert-sync-agent_1.5.0_all.deb

Các địa chỉ `curl` ở trên chỉ chạy được với repo public. Với repo **private**, tải bằng `gh` trên máy quản trị rồi `scp` lên server:

    gh auth login
    gh release download v1.5.0 -R <tổ-chức>/<repo> -p '*.deb' -p '*.tar.gz' -p SHA256SUMS -D /tmp/rel
    cd /tmp/rel && sha256sum -c SHA256SUMS

Thiết lập repo GitHub từ đầu (tạo repo, bảo vệ nhánh `main`, phát hành bằng tag) nằm trong tài liệu `Huong-dan-build-he-thong-thay-cert-PortSIP.docx`, mục 8.5 đến 8.8.

Cả hai cách đều không bao giờ ghi đè `config.conf`, `telegram.conf`, `sbc.cred` đã có trên server.
Nếu dùng hồ sơ và server đã có `config.conf`, bản của hồ sơ được lưu thành `config.conf.new` để bạn so (`diff`).

## Nhiều server, mỗi nơi chỉnh một ít

- **Mã dùng chung một bản.** Không tạo nhánh riêng cho từng server.
- **Khác biệt nằm ở `profiles/<tên-server>/config.conf`** (domain, cổng, khung giờ, ngưỡng...). Xem khác biệt giữa hai server:
  `git diff --no-index profiles/a profiles/b`.
- **Thêm server mới:** `cp -r profiles/_template profiles/ten-server`, sửa, commit, mở PR.
- **Bí mật không bao giờ vào repo:** `telegram.conf` và `sbc.cred` nhập tay trên từng server. `.gitignore` đã chặn.

## Nhánh và phiên bản

| Thành phần | Quy tắc |
|---|---|
| `main` | Luôn ổn định, chỉ nhận mã đã qua CI |
| `feature/...`, `fix/...` | Nhánh ngắn hạn cho mỗi thay đổi; xong thì mở Pull Request vào `main` |
| Tag `vX.Y.Z` | Mỗi bản phát hành; server chỉ cài từ tag |
| `release/1.x` | Chỉ tạo khi cần vá lỗi cho bản cũ trong lúc `main` đã sang 2.x |

Số phiên bản: `X` đổi khi thay đổi làm hỏng cấu hình cũ, `Y` khi thêm tính năng, `Z` khi sửa lỗi.

## Phát hành

1. Sửa `VERSION` (ví dụ `1.1.0`) và thêm mục vào `CHANGELOG.md`, mở PR vào `main`, CI phải xanh.
2. Sau khi merge: `git tag v1.1.0 && git push origin v1.1.0`.
3. GitHub Actions (`.github/workflows/release.yml`) kiểm tra tag khớp `VERSION`, chạy kiểm thử, chạy `make release` (tarball mã nguồn, tarball agent, gói đầy đủ, gói agent) và sinh `SHA256SUMS` và tạo Release.

## Nâng cấp và quay lại

    cert-deploy.sh version                       # server đang chạy bản nào
    git fetch --tags && git checkout v1.5.0 && sudo ./install.sh
    # quay lại: git checkout v1.4.0 && sudo ./install.sh

Nên nâng cấp server thử nghiệm trước, chạy `sudo health-check.sh`, rồi mới tới server khác.

## Kiểm thử

    make lint     # bash -n và shellcheck mức lỗi
    make test     # bộ chính (vài phút), phần container và phần hai VM; cần openssl, jq, inotify-tools
    make image    # dựng image container (cần Docker)
    make deb      # gói đầy đủ trong dist/ (VERSION=1.5.1 để đổi số bản)
    make release  # tất cả sản phẩm và SHA256SUMS

`tests/test-renew.sh` cần thêm một bản Caddy (đặt `CADDY=/đường/dẫn/caddy`) nên không nằm trong CI.

## Chạy bằng container (tuỳ chọn)

Hợp khi PortSIP của bạn đã chạy bằng Docker/compose và bạn muốn ghim phiên bản bằng tag image, không cài gói lên máy chủ.
Nếu máy chủ đã có systemd, gói `.deb` đơn giản hơn và cần ít quyền hơn.

    docker compose -f container/compose.example.yml up -d      # sửa image, múi giờ và các đường dẫn volume trước

Điều kiện bắt buộc (đã ghi trong `container/compose.example.yml`):

- `network_mode: host`: script đo cert qua `127.0.0.1` và gọi API SBC ở `127.0.0.1:8883`.
- Gắn volume giữ **nguyên đường dẫn** như trên máy chủ, nên cùng một `config.conf` dùng được cho cả hai cách chạy.
- `TZ` phải trùng múi giờ máy chủ. Khung giờ 22:00-05:00 tính theo giờ trong container; để mặc định UTC thì khung giờ lệch 7 tiếng so với giờ Việt Nam.
- Gắn `/var/run/docker.sock` để chạy `docker restart portsip.webserver`.

Image thay systemd bằng một bộ lập lịch nhỏ (`container/entrypoint.sh`):

| systemd | Trong container |
|---|---|
| `caddy-cert-sync.service` | Entrypoint chạy watcher, chết thì khởi động lại và báo Telegram |
| `caddy-cert-apply.timer` | Mỗi 15 phút, chỉ trong khung giờ, gọi `cert-deploy.sh apply` |
| `caddy-cert-stuck-check.timer` | Mỗi giờ gọi `cert-deploy.sh stuck` |
| `caddy-cert-sync-watchdog.timer` | Không cần: entrypoint đã giám sát watcher; Docker `HEALTHCHECK` kiểm tra tiến trình watcher |
| `caddy-cert-expiry-check.timer` | 09:00 hằng ngày gọi `cert-deploy.sh expiry` |

**Cảnh báo bảo mật:** gắn `docker.sock` cho container tương đương cấp quyền root trên máy chủ. Nếu muốn giảm, đặt một socket proxy
chỉ cho phép các lệnh `restart`, `exec`, `ps`, `inspect` ở giữa (chưa thử).

Không dùng trong container: `check-sync-alive.sh`, `renew-status.sh`, `set-renew-days.sh` (dành cho máy chủ có systemd và Caddy chạy trên máy).
`health-check.sh` tự bỏ qua phần systemd khi không có systemd.

Kiểm tra sau khi chạy: `docker exec cert-sync date` (so với giờ máy chủ), `docker exec cert-sync cert-deploy.sh status`,
`docker logs cert-sync`, `docker inspect --format '{{.State.Health.Status}}' cert-sync`.

**Mức kiểm thử:** bộ lập lịch và `health-check.sh` đã được thử ngoài Docker (`tests/test-container.sh`). Image **chưa được dựng và chạy** với Docker thật,
nên lần dựng đầu tiên (`make image`) và lần chạy đầu trên server là phép thử thật.

## Quy tắc vận hành

1. **Chỉ thay khi có cert chờ áp dụng** (dấu `pending` do bước chuẩn bị tạo ra). Không có cert chờ thì không thay gì; nếu cổng đang phục vụ cert khác cert đã chuẩn bị, hệ thống chỉ cảnh báo. Muốn ép: `cert-deploy.sh now --force`.
2. **PBX trước, SBC sau**, trong khung giờ bảo trì (hoặc khi chạy `now`).
3. **Một bên lỗi thì hoàn tác cả hai về cert cũ**, xác minh bằng serial, rồi báo Telegram. Không hoàn tác được thì báo "CẦN KIỂM TRA TAY" và dừng tự thử lại.
4. **Thử lại có giới hạn**: `MAX_AUTO_ATTEMPTS` (mặc định 2) cho mỗi cert; hết lượt thì dừng và cảnh báo. Lệnh `now` không tính vào giới hạn.
5. **Mọi kết quả đều có tin Telegram**: `[1/2]` có cert chờ, `[2/2]` thành công hoặc có lỗi (kèm kết quả hoàn tác và bước tiếp), dừng tự động, cảnh báo lệch cert, cert sắp hết hạn.

## Hai mô hình triển khai

| | A. Cùng VM | B. Khác VM |
|---|---|---|
| Hệ thống thay cert chạy ở | VM duy nhất | VM SBC |
| PBX | `pbx-agent.sh` chạy tại chỗ | qua SSH tới `pbx-agent.sh` trên VM PBX |
| Cài trên VM PBX | (cùng VM) | chỉ agent và một file cấu hình |
| Hồ sơ | `same-vm` | `diff-vm` |

**Mô hình A (cùng VM):**

    sudo ./install.sh --profile same-vm
    sudo nano /etc/caddy-cert-sync/config.conf /etc/caddy-cert-sync/telegram.conf /etc/caddy-cert-sync/sbc.cred
    sudo cert-deploy.sh baseline /var/lib/portsip/pbx/certificates/portsip.crt /var/lib/portsip/pbx/certificates/portsip.key
    sudo cert-deploy.sh status
    sudo ./install.sh --enable

**Mô hình B (khác VM).** Trên VM PBX:

    sudo ./install.sh --agent                 # cài /usr/local/bin/pbx-agent.sh và tạo /etc/pbx-cert-agent.conf
    sudo nano /etc/pbx-cert-agent.conf        # PBX_CRT, PBX_KEY, PORTSIP_UID/GID, PBX_RESTART_CONTAINERS cho khớp VM này

Thêm khoá công khai của VM SBC vào `authorized_keys` trên VM PBX, một dòng, có ràng buộc lệnh (khoá chỉ chạy được agent, không có shell):

    restrict,command="/usr/local/bin/pbx-agent.sh",from="IP-VM-SBC" ssh-ed25519 AAAA... cert-sync

Nếu dùng root, đặt `PermitRootLogin forced-commands-only`. Trên VM SBC:

    sudo ssh-keygen -t ed25519 -N "" -C cert-sync -f /etc/caddy-cert-sync/pbx_ssh_key
    sudo sh -c 'ssh-keyscan -t ed25519 10.0.0.1 > /etc/caddy-cert-sync/known_hosts'
    ssh-keygen -lf /etc/caddy-cert-sync/known_hosts      # SO vân tay với: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub chạy trên VM PBX
    sudo ./install.sh --profile diff-vm                  # sửa TODO: PBX_SSH, PBX_PORTS, SBC_*
    sudo ssh -i /etc/caddy-cert-sync/pbx_ssh_key -o UserKnownHostsFile=/etc/caddy-cert-sync/known_hosts root@10.0.0.1 ping   # phải in: pbx-agent ok
    scp root@10.0.0.1:/var/lib/portsip/pbx/certificates/portsip.crt /var/lib/portsip/pbx/certificates/portsip.key /root/
    sudo cert-deploy.sh baseline /root/portsip.crt /root/portsip.key && shred -u /root/portsip.crt /root/portsip.key
    sudo cert-deploy.sh status
    sudo ./install.sh --enable

Mốc hoàn tác (`baseline`) là cặp cert **đang chạy trên SBC**; với PortSIP thường là cùng cặp với PBX. Nếu không đặt mốc, lần thay đầu tiên mà SBC lỗi sau `DeleteCert` thì không có gì để khôi phục và hệ thống báo "CẦN KIỂM TRA TAY".

Mỗi lượt thay PBX: `ping`, `put crt`, `put key` (VM PBX tính sha256 để đối chiếu), `commit` (kiểm tra cặp mới đọc được và khoá khớp cert, sao lưu cặp cũ thành `.prev`, đổi tên nguyên tử), `restart`, rồi đo serial qua mạng. Lỗi từ `restart` trở đi thì `rollback`, restart lại và xác minh bằng serial cũ.

**Nguồn cert:** Caddy hoặc lego (đặt `CADDY_CERT_BASE` trỏ vào thư mục chứa `certificates/`), hoặc dán tay bằng `sudo paste-cert.sh` (kiểm tra khoá khớp, domain, hạn, chuỗi rồi đặt vào `$CADDY_CERT_BASE/certificates/manual/`). Cert dán tay không tự gia hạn; `cert-deploy.sh expiry` (timer 09:00 hằng ngày) báo Telegram khi cert đang dùng còn 30, 14, 7, 3, 1 ngày.

**Mức kiểm thử:** bộ kiểm thử mô phỏng PBX, SBC, SSH và Telegram; thêm một `sshd` thật ở cổng riêng để thử khoá ràng buộc lệnh. **Chưa thử với hai VM thật và firewall thật.**

## Bí mật

Không commit: `telegram.conf`, `sbc.cred`, khoá riêng (`*.key`, `*.pem`), mật khẩu, token. Nếu lỡ commit,
**coi như đã lộ**: đổi giá trị đó ngay, xoá khỏi lịch sử Git không đủ vì bản sao có thể đã được tải về.
Nên đặt repo ở chế độ private, và bật quét bí mật của GitHub nếu gói của bạn có.
