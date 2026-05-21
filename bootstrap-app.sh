#!/bin/bash
# Bootstrap script: setup VPS App từ A-Z
# Cài Node.js 22, Go 1.22, PM2
# Clone services, build, deploy bằng PM2
#
# Usage: sudo ./bootstrap-app.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============ MÀU SẮC ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()   { echo -e "${BLUE}ℹ${NC}  $1"; }
log_ok()     { echo -e "${GREEN}✓${NC}  $1"; }
log_warn()   { echo -e "${YELLOW}⚠${NC}  $1"; }
log_error()  { echo -e "${RED}✗${NC}  $1"; }
log_step()   { echo ""; echo -e "${BLUE}═══ $1 ═══${NC}"; }
log_action() { echo -e "${YELLOW}→${NC}  $1"; }

ask_yn() {
  local prompt="$1"
  local default="${2:-y}"
  local answer
  if [ "$default" = "y" ]; then
    read -p "$(echo -e "${YELLOW}?${NC}  $prompt [Y/n]: ")" answer
    answer="${answer:-y}"
  else
    read -p "$(echo -e "${YELLOW}?${NC}  $prompt [y/N]: ")" answer
    answer="${answer:-n}"
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ============ CẤU HÌNH ============
GITHUB_USER="DANG-PH"
SERVICES_LIST="$SCRIPT_DIR/services.list"
NODE_VERSION="22"
GO_VERSION="1.22.0"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SERVICES_DIR="$REAL_HOME/dragonboy-services"

# ============ CHECK ROOT ============
if [ "$EUID" -ne 0 ]; then
  log_error "Script này phải chạy với quyền root."
  log_warn "Chạy: sudo $0"
  exit 1
fi

if [ ! -f "$SERVICES_LIST" ]; then
  log_error "Không tìm thấy $SERVICES_LIST"
  exit 1
fi

# ============ BANNER ============
clear
cat <<'EOF'
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║       BOOTSTRAP APP - dragonboy services                 ║
║                                                          ║
║    1.  Cài tool cơ bản                                   ║
║    2.  Set timezone Asia/Ho_Chi_Minh                     ║
║    3.  Tạo swap 2GB + vm.swappiness=10                   ║
║    4.  UFW (22,80,443 + whitelist IP nginx → ports nội bộ)║
║    5.  Cài Node.js 22 + pm2 + pm2-logrotate              ║
║    6.  Cài Go 1.22 + air (hot reload)                    ║
║    7.  Tailscale (optional)                              ║
║    8.  Clone services từ GitHub                          ║
║    9.  Copy .env.example → .env + nano điền              ║
║    10. npm install + npm run build (NestJS)              ║
║    11. go build -o <name> ./cmd/api/main.go (Go)         ║
║    12. pm2 start -i max                                  ║
║    13. pm2 save + pm2 startup                            ║
║    14. Healthcheck tất cả services                       ║
║                                                          ║
║  Thời gian: ~20-30 phút                                  ║
╚══════════════════════════════════════════════════════════╝
EOF
echo ""
log_info "User:         $REAL_USER"
log_info "Home:         $REAL_HOME"
log_info "Services dir: $SERVICES_DIR"
log_info "Số service:   $(grep -cv '^#\|^$' "$SERVICES_LIST")"
echo ""

if ! ask_yn "Bắt đầu setup?"; then
  log_warn "Đã huỷ."
  exit 0
fi

# ============ NHẬP IP NGINX VPS ============
log_step "Cấu hình IP VPS Nginx (UFW whitelist)"

NGINX_VPS_IP=""
while true; do
  read -p "$(echo -e "${YELLOW}?${NC}  IP của VPS Nginx: ")" NGINX_VPS_IP
  if [[ "$NGINX_VPS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    log_ok "Nginx VPS IP: $NGINX_VPS_IP"
    break
  else
    log_error "IP không hợp lệ, nhập lại."
  fi
done

read -p "$(echo -e "${YELLOW}?${NC}  Các port nội bộ services (cách nhau bằng dấu cách, vd: 3000 3001 3002): ")" -a INTERNAL_PORTS
log_ok "Internal ports: ${INTERNAL_PORTS[*]}"

# ============ BƯỚC 1: TOOL CƠ BẢN ============
log_step "Bước 1/14: Cài tool cơ bản"

apt update -qq
apt install -y -qq \
  curl wget git \
  vim nano \
  htop ncdu \
  net-tools dnsutils \
  unzip zip tar \
  jq \
  build-essential \
  ca-certificates \
  gnupg \
  lsb-release

log_ok "Đã cài tool cơ bản"

# ============ BƯỚC 2: TIMEZONE ============
log_step "Bước 2/14: Set timezone"

CURRENT_TZ=$(timedatectl show --property=Timezone --value)
if [ "$CURRENT_TZ" = "Asia/Ho_Chi_Minh" ]; then
  log_ok "Timezone: Asia/Ho_Chi_Minh"
else
  timedatectl set-timezone Asia/Ho_Chi_Minh
  log_ok "Timezone: $(timedatectl show --property=Timezone --value)"
fi

# ============ BƯỚC 3: SWAP ============
log_step "Bước 3/14: Swap 2GB + vm.swappiness"

if swapon --show | grep -q "/swapfile"; then
  log_ok "Swap đã tồn tại"
else
  log_action "Tạo swap 2GB..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  log_ok "Đã tạo swap 2GB"
fi

# [PATCH] vm.swappiness=10 — chỉ dùng swap khi RAM còn 10%, tránh swap quá sớm
if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
  echo 'vm.swappiness=10' >> /etc/sysctl.conf
  sysctl -p > /dev/null
  log_ok "vm.swappiness=10"
else
  log_ok "vm.swappiness đã config"
fi

# ============ BƯỚC 4: UFW ============
log_step "Bước 4/14: UFW Firewall"

if ! command -v ufw &> /dev/null; then
  apt install -y -qq ufw
fi

UFW_STATUS=$(ufw status | head -1)
if echo "$UFW_STATUS" | grep -q "Status: active"; then
  log_warn "UFW đã active, chỉ thêm rule mới nếu thiếu"
else
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp   comment 'SSH'
  ufw allow 80/tcp   comment 'HTTP'
  ufw allow 443/tcp  comment 'HTTPS'
  ufw --force enable
  log_ok "UFW active"
fi

# [PATCH] Whitelist IP Nginx → các port nội bộ
# Không expose port app ra internet, chỉ cho phép VPS Nginx gọi vào
log_action "Whitelist $NGINX_VPS_IP → internal ports..."
for port in "${INTERNAL_PORTS[@]}"; do
  # Kiểm tra rule đã tồn tại chưa trước khi thêm
  if ! ufw status | grep -q "$NGINX_VPS_IP.*$port"; then
    ufw allow from "$NGINX_VPS_IP" to any port "$port" comment "Nginx VPS → app port $port"
    log_ok "Allow $NGINX_VPS_IP → :$port"
  else
    log_ok "Rule $NGINX_VPS_IP → :$port đã tồn tại"
  fi
done

# ============ BƯỚC 5: NODE.JS + PM2 + LOGROTATE ============
log_step "Bước 5/14: Node.js $NODE_VERSION + pm2 + pm2-logrotate"

if command -v node &> /dev/null; then
  CURRENT_NODE=$(node --version | grep -oP '\d+' | head -1)
  if [ "$CURRENT_NODE" = "$NODE_VERSION" ]; then
    log_ok "Node.js $(node --version) đã cài"
  else
    log_warn "Node.js version cũ: $(node --version), cần $NODE_VERSION"
    if ask_yn "Cài lại?"; then
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
      apt install -y nodejs
    fi
  fi
else
  log_action "Cài Node.js $NODE_VERSION..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
  apt install -y nodejs
  log_ok "Node.js $(node --version), npm $(npm --version)"
fi

if command -v pm2 &> /dev/null; then
  log_ok "pm2 đã cài: $(pm2 --version)"
else
  log_action "Cài pm2 globally..."
  npm install -g pm2
  log_ok "pm2 $(pm2 --version)"
fi

# [PATCH] PM2 logrotate — tránh log đầy disk trên production
if sudo -u "$REAL_USER" pm2 list 2>/dev/null | grep -q "pm2-logrotate"; then
  log_ok "pm2-logrotate đã cài"
else
  log_action "Cài pm2-logrotate..."
  sudo -u "$REAL_USER" pm2 install pm2-logrotate
  sudo -u "$REAL_USER" pm2 set pm2-logrotate:max_size 50M
  sudo -u "$REAL_USER" pm2 set pm2-logrotate:retain 7
  sudo -u "$REAL_USER" pm2 set pm2-logrotate:compress true
  log_ok "pm2-logrotate: max 50M, giữ 7 ngày, nén"
fi

# ============ BƯỚC 6: GO + AIR ============
log_step "Bước 6/14: Go $GO_VERSION + air (hot reload)"

GO_BIN="/usr/local/go/bin/go"
INSTALL_GO=0

if [ -f "$GO_BIN" ]; then
  INSTALLED_GO=$($GO_BIN version | grep -oP 'go\d+\.\d+\.\d+' | head -1)
  if [ "$INSTALLED_GO" = "go$GO_VERSION" ]; then
    log_ok "Go $INSTALLED_GO đã cài"
  else
    log_warn "Go khác version: $INSTALLED_GO (cần go$GO_VERSION)"
    if ask_yn "Cài lại Go $GO_VERSION?"; then
      rm -rf /usr/local/go
      INSTALL_GO=1
    fi
  fi
else
  INSTALL_GO=1
fi

if [ "$INSTALL_GO" = "1" ]; then
  log_action "Tải Go $GO_VERSION..."
  cd /tmp
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  log_action "Cài Go..."
  tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
  rm -f "go${GO_VERSION}.linux-amd64.tar.gz"
  log_ok "Go $(/usr/local/go/bin/go version)"
fi

# [PATCH] Thêm Go vào /etc/profile.d/ thay vì ~/.bashrc
# PM2 chạy non-interactive shell → không đọc .bashrc → Go không tìm thấy
if [ ! -f /etc/profile.d/golang.sh ]; then
  echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/golang.sh
  chmod 644 /etc/profile.d/golang.sh
  log_ok "Go PATH → /etc/profile.d/golang.sh (PM2 sẽ nhận được)"
else
  log_ok "Go PATH đã config"
fi

# Cho session hiện tại
export PATH=$PATH:/usr/local/go/bin

# Thêm vào .bashrc của user (tiện khi ssh vào dev)
if ! grep -q "/usr/local/go/bin" "$REAL_HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH=$PATH:/usr/local/go/bin' >> "$REAL_HOME/.bashrc"
fi

# [PATCH] Cài air — hot reload cho Go khi dev
# Dùng: air (thay vì go run) để tự restart khi code thay đổi
if command -v air &> /dev/null; then
  log_ok "air đã cài: $(air -v 2>&1 | head -1)"
else
  log_action "Cài air (hot reload Go)..."
  sudo -u "$REAL_USER" -i bash -c "
    export PATH=\$PATH:/usr/local/go/bin
    export GOPATH=\$HOME/go
    go install github.com/air-verse/air@latest
  "
  # Symlink air vào /usr/local/bin để dùng được toàn hệ thống
  AIR_BIN="$REAL_HOME/go/bin/air"
  if [ -f "$AIR_BIN" ]; then
    ln -sf "$AIR_BIN" /usr/local/bin/air
    log_ok "air installed → /usr/local/bin/air"
  else
    log_warn "air install thất bại, bỏ qua"
  fi
fi

# ============ BƯỚC 7: TAILSCALE ============
log_step "Bước 7/14: Tailscale (mesh VPN)"

if command -v tailscale &> /dev/null; then
  log_ok "Tailscale đã cài: $(tailscale version | head -1)"
else
  if ask_yn "Cài Tailscale (mesh VPN giữa các VPS)?" "n"; then
    curl -fsSL https://tailscale.com/install.sh | sh
    log_warn "Sau bootstrap xong, chạy: tailscale up"
  else
    log_info "Bỏ qua Tailscale"
  fi
fi

# ============ BƯỚC 8: CLONE SERVICES ============
log_step "Bước 8/14: Clone $(grep -cv '^#\|^$' "$SERVICES_LIST") services"

mkdir -p "$SERVICES_DIR"
chown "$REAL_USER:$REAL_USER" "$SERVICES_DIR"

while IFS='|' read -r repo pm2_name service_type; do
  [[ "$repo" =~ ^#.*$ || -z "$repo" ]] && continue

  SERVICE_PATH="$SERVICES_DIR/$repo"
  REPO_URL="https://github.com/$GITHUB_USER/$repo.git"

  if [ -d "$SERVICE_PATH/.git" ]; then
    log_ok "$repo đã clone, pull mới nhất..."
    cd "$SERVICE_PATH"
    sudo -u "$REAL_USER" git pull origin master 2>/dev/null \
      || sudo -u "$REAL_USER" git pull origin main 2>/dev/null \
      || log_warn "Pull $repo thất bại"
  else
    log_action "Clone $repo..."
    sudo -u "$REAL_USER" git clone "$REPO_URL" "$SERVICE_PATH" || {
      log_error "Clone $repo fail. URL: $REPO_URL"
      continue
    }
    log_ok "Cloned $repo"
  fi
done < "$SERVICES_LIST"

# ============ BƯỚC 9: TẠO .ENV ============
log_step "Bước 9/14: Tạo .env cho từng service"

log_warn "Sẽ mở nano cho từng service để điền .env"
if ! ask_yn "Bắt đầu config .env?"; then
  log_warn "Skip. Bạn cần tự tạo .env cho từng service trước khi build."
else
  while IFS='|' read -r repo pm2_name service_type; do
    [[ "$repo" =~ ^#.*$ || -z "$repo" ]] && continue

    SERVICE_PATH="$SERVICES_DIR/$repo"
    [ ! -d "$SERVICE_PATH" ] && { log_warn "Skip $repo (chưa clone)"; continue; }

    cd "$SERVICE_PATH"

    if [ -f ".env" ]; then
      log_ok "$repo/.env đã tồn tại"
      if ask_yn "Sửa lại $repo/.env?" "n"; then
        nano .env
      fi
    elif [ -f ".env.example" ]; then
      cp .env.example .env
      chmod 600 .env
      chown "$REAL_USER:$REAL_USER" .env
      log_warn "Mở nano: $repo/.env..."
      sleep 1
      nano .env
    else
      log_warn "$repo không có .env.example, tạo file rỗng"
      touch .env
      chmod 600 .env
      chown "$REAL_USER:$REAL_USER" .env
      nano .env
    fi
  done < "$SERVICES_LIST"
fi

# ============ BƯỚC 10: BUILD NESTJS ============
log_step "Bước 10/14: Build NestJS services"

while IFS='|' read -r repo pm2_name service_type; do
  [[ "$repo" =~ ^#.*$ || -z "$repo" ]] && continue
  [ "$service_type" != "nestjs" ] && continue

  SERVICE_PATH="$SERVICES_DIR/$repo"
  [ ! -d "$SERVICE_PATH" ] && { log_warn "Skip $repo (chưa clone)"; continue; }

  cd "$SERVICE_PATH"

  # npm install — giữ nguyên (không dùng ci, tránh lỗi lockfile không sync)
  log_action "[$repo] npm install..."
  sudo -u "$REAL_USER" npm install --silent

  log_action "[$repo] npm run build..."
  sudo -u "$REAL_USER" npm run build

  if [ ! -f "dist/src/main.js" ]; then
    log_error "[$repo] Build fail — không thấy dist/src/main.js"
    continue
  fi
  log_ok "[$repo] Build OK"
done < "$SERVICES_LIST"

# ============ BƯỚC 11: BUILD GO ============
log_step "Bước 11/14: Build Go services"

# [PATCH] Đúng entrypoint Go: ./cmd/api/main.go (theo note)
while IFS='|' read -r repo pm2_name service_type; do
  [[ "$repo" =~ ^#.*$ || -z "$repo" ]] && continue
  [ "$service_type" != "go" ] && continue

  SERVICE_PATH="$SERVICES_DIR/$repo"
  [ ! -d "$SERVICE_PATH" ] && { log_warn "Skip $repo (chưa clone)"; continue; }

  cd "$SERVICE_PATH"
  log_action "[$repo] go build -o $pm2_name ./cmd/api/main.go..."
  sudo -u "$REAL_USER" -i bash -c "
    export PATH=\$PATH:/usr/local/go/bin
    cd $SERVICE_PATH
    go build -o $pm2_name ./cmd/api/main.go
  "

  if [ ! -f "$pm2_name" ]; then
    log_error "[$repo] Build fail — không thấy binary: $pm2_name"
    continue
  fi
  chmod +x "$pm2_name"
  log_ok "[$repo] Build OK → ./$pm2_name"
done < "$SERVICES_LIST"

# ============ BƯỚC 12: PM2 START ============
log_step "Bước 12/14: PM2 start tất cả services"

while IFS='|' read -r repo pm2_name service_type; do
  [[ "$repo" =~ ^#.*$ || -z "$repo" ]] && continue

  SERVICE_PATH="$SERVICES_DIR/$repo"

  if sudo -u "$REAL_USER" pm2 list 2>/dev/null | grep -q "$pm2_name"; then
    log_warn "[$pm2_name] đang chạy → restart --update-env"
    sudo -u "$REAL_USER" pm2 restart "$pm2_name" --update-env
  else
    if [ "$service_type" = "nestjs" ]; then
      log_action "[$pm2_name] pm2 start NestJS..."
      sudo -u "$REAL_USER" pm2 start "$SERVICE_PATH/dist/src/main.js" \
        --name "$pm2_name" \
        -i max \
        --cwd "$SERVICE_PATH"

    elif [ "$service_type" = "go" ]; then
      log_action "[$pm2_name] pm2 start Go binary..."
      sudo -u "$REAL_USER" pm2 start "$SERVICE_PATH/$pm2_name" \
        --name "$pm2_name" \
        -i max \
        --cwd "$SERVICE_PATH"
    fi
  fi
done < "$SERVICES_LIST"

# ============ BƯỚC 13: PM2 SAVE + STARTUP ============
log_step "Bước 13/14: PM2 save + startup"

sudo -u "$REAL_USER" pm2 save

log_action "Setup PM2 startup (tự bật khi reboot)..."
PM2_STARTUP_CMD=$(sudo -u "$REAL_USER" pm2 startup systemd -u "$REAL_USER" --hp "$REAL_HOME" | grep "sudo env" || echo "")
if [ -n "$PM2_STARTUP_CMD" ]; then
  eval "$PM2_STARTUP_CMD"
  log_ok "PM2 startup OK"
else
  log_warn "PM2 startup có thể đã setup, hoặc chạy thủ công: pm2 startup"
fi

# ============ BƯỚC 14: HEALTHCHECK ============
log_step "Bước 14/14: Healthcheck"

log_action "Đợi 5s để services khởi động..."
sleep 5

FAILED=0
while IFS='|' read -r repo pm2_name service_type; do
  [[ "$repo" =~ ^#.*$ || -z "$repo" ]] && continue

  STATUS=$(sudo -u "$REAL_USER" pm2 jlist 2>/dev/null \
    | jq -r --arg name "$pm2_name" '.[] | select(.name==$name) | .pm2_env.status' \
    | head -1)

  if [ "$STATUS" = "online" ]; then
    log_ok "[$pm2_name] online ✓"
  else
    log_error "[$pm2_name] STATUS: ${STATUS:-không tìm thấy} ✗"
    FAILED=$((FAILED + 1))
  fi
done < "$SERVICES_LIST"

echo ""
if [ "$FAILED" -gt 0 ]; then
  log_warn "$FAILED service lỗi. Kiểm tra: pm2 logs <name>"
else
  log_ok "Tất cả services online!"
fi

# ============ HOÀN TẤT ============
echo ""
cat <<EOF
${GREEN}╔══════════════════════════════════════════════════════════╗
║                                                          ║
║           ✓ BOOTSTRAP APP HOÀN TẤT                       ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝${NC}

${BLUE}Đã setup:${NC}
  ✓ Tool cơ bản + timezone + swap (swappiness=10)
  ✓ UFW: 22, 80, 443 + whitelist $NGINX_VPS_IP → ${INTERNAL_PORTS[*]}
  ✓ Node.js $(node --version 2>/dev/null || echo $NODE_VERSION) + pm2 + pm2-logrotate (50M, 7 ngày)
  ✓ Go $GO_VERSION + air (hot reload) → PATH qua /etc/profile.d/
  ✓ Clone + .env + build + pm2 start -i max
  ✓ PM2 startup (auto restart khi reboot)
  ✓ Healthcheck

${BLUE}Lệnh hữu ích:${NC}
  ${YELLOW}pm2 list${NC}                       — Trạng thái tất cả services
  ${YELLOW}pm2 logs <name>${NC}                — Log realtime
  ${YELLOW}pm2 restart <name> --update-env${NC} — Restart 1 service
  ${YELLOW}pm2 monit${NC}                      — Dashboard CPU/RAM

${BLUE}Update 1 service (NestJS):${NC}
  cd $SERVICES_DIR/<repo>
  git pull && npm install && npm run build
  pm2 restart <name> --update-env

${BLUE}Update 1 service (Go):${NC}
  cd $SERVICES_DIR/<repo>
  git pull
  go build -o <name> ./cmd/api/main.go
  pm2 restart <name> --update-env

${BLUE}Dev Go với hot reload:${NC}
  cd $SERVICES_DIR/<repo>
  air

${YELLOW}LƯU Ý:${NC}
  - Nếu cài Tailscale: tailscale up (rồi login)
  - PM2 dashboard: https://app.pm2.io
  - Log files: ~/.pm2/logs/
EOF