# dragonboy-deploy-scripts

Bootstrap scripts để setup VPS mới cho dragonboy stack.

## Sử dụng

### VPS App (loại 2)

VPS chạy 11 NestJS service + 1 Go service.

```bash
git clone https://github.com/DANG-PH/dragonboy-deploy-scripts.git
cd dragonboy-deploy-scripts
sudo ./bootstrap-app.sh
```

Script tự động:
1. Cài tool cơ bản, timezone, swap
2. UFW (22, 80, 443)
3. Cài Node.js 22, pm2, Go 1.22
4. Clone 12 service từ GitHub
5. Tạo `.env` cho từng service (nano interactive)
6. Build NestJS (`npm install && npm run build`)
7. Build Go (`go build`)
8. PM2 start tất cả với `-i max`
9. PM2 save + startup (auto-restart khi reboot)

Thời gian: ~20-30 phút.

### Sửa danh sách service

Sửa file `services.list`:
repo_name|pm2_name|type

`type` có thể là `nestjs` hoặc `go`.

## Manage services

```bash
pm2 list                       # Xem trạng thái
pm2 logs <service-name>        # Xem log
pm2 restart <service-name>     # Restart
pm2 monit                      # Dashboard real-time
```

## Update code

```bash
cd ~/dragonboy-services/<repo>
git pull
# NestJS:
npm install && npm run build
# Go:
go build -o <pm2-name> ./cmd/api/main.go
# Cả 2:
pm2 restart <pm2-name>
```