# Hồ sơ theo server

Mỗi thư mục là một server (hoặc một mô hình mẫu); bên trong chỉ có `config.conf` (các giá trị KHÔNG bí mật: domain, cổng, khung giờ, ngưỡng).
Khác biệt giữa các server nằm ở đây, nên xem bằng `git diff --no-index profiles/a profiles/b`.

| Hồ sơ | Dùng cho |
|---|---|
| `same-vm` | Mô hình A: một VM chạy cả PBX, SBC và hệ thống thay cert |
| `diff-vm` | Mô hình B: hệ thống chạy trên VM SBC; PBX ở VM khác, thay cert qua SSH tới pbx-agent.sh |
| `_template` | Khuôn cho server mới (giống same-vm) |
| `ecs-jqpd` | Server thử nghiệm hiện tại (cùng VM) |

Thêm server mới: `cp -r profiles/same-vm profiles/ten-server`, sửa rồi commit.
Bí mật (`telegram.conf`, `sbc.cred`) KHÔNG bao giờ nằm trong repo: nhập tay trên từng server.
