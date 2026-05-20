#!/bin/bash
# Bootstrap script: setup VPS App từ A-Z
# Cài Node.js 22, Go 1.22, PM2
# Clone 12 service, build, deploy bằng PM2
#
# Usage: sudo ./bootstrap-app.sh

set -euo pipefail

# ============ ĐỊNH VỊ ============
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

pause() { read -p "$(echo -e "${YELLOW}Enter để tiếp tục...${NC}")"; }

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
SERVICES_DIR="$HOME/dragonboy-services"
SERVICES_LIST="$SCRIPT_DIR/services.list"
NODE_VERSION="22"
GO_VERSION="1.22.0"

# Lấy user thật sự (vì chạy bằng sudo, $HOME có thể là /root)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SERVICES_DIR="$REAL_HOME/dragonboy-services"

# ============ CHECK ROOT ============
if [ "$EUID" -ne 0 ]; then
  log_error "Script này phải chạy với quyền root."
  log_warn "Chạy: sudo $0"
  exit 1
fi

# Check services.list
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
║  Script tự động setup VPS App từ A-Z:                    ║
║    1. Cài tool cơ bản                                    ║
║    2. Set timezone Asia/Ho_Chi_Minh                      ║
║    3. Tạo swap 2GB                                       ║
║    4. UFW (22, 80, 443)                                  ║
║    5. Cài Node.js 22 + npm + pm2                         ║
║    6. Cài Go 1.22                                        ║
║    7. Tailscale (optional)                               ║
║    8. Clone 12 service từ GitHub                         ║
║    9. Copy .env.example → .env + nano để user điền       ║
║   10. npm install + npm run build (11 NestJS)            ║
║   11. go build (1 Go service)                            ║
║   12. pm2 start --name <service> -i max                  ║
║   13. pm2 save + pm2 startup                             ║
║                                                          ║
║  Thời gian: ~20-30 phút                                  ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
EOF
echo ""
log_info "User: $REAL_USER"
log_info "Home: $REAL_HOME"
log_info "Services dir: $SERVICES_DIR"
log_info "Số service: $(grep -cv '^#\|^$' "$SERVICES_LIST")"
echo ""

if ! ask_yn "Bắt đầu setup?"; then
  log_warn "Đã huỷ."
  exit 0
fi

# ============ BƯỚC 1: TOOL CƠ BẢN ============
log_step "Bước 1/13: Cài tool cơ bản"

log_action "apt update..."
apt update -qq

log_action "Cài tool..."
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
log_step "Bước 2/13: Set timezone"

CURRENT_TZ=$(timedatectl show --property=Timezone --value)
if [ "$CURRENT_TZ" = "Asia/Ho_Chi_Minh" ]; then
  log_ok "Timezone: Asia/Ho_Chi_Minh"
else
  timedatectl set-timezone Asia/Ho_Chi_Minh
  log_ok "Timezone: $(timedatectl show --property=Timezone --value)"
fi

# ============ BƯỚC 3: SWAP ============
log_step "Bước 3/13: Swap 2GB"

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

# ============ BƯỚC 4: UFW ============
log_step "Bước 4/13: UFW Firewall"

if ! command -v ufw &> /dev/null; then
  apt install -y -qq ufw
fi

UFW_STATUS=$(ufw status | head -1)
if echo "$UFW_STATUS" | grep -q "Status: active"; then
  log_warn "UFW đã active, bỏ qua."
else
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw --force enable
  log_ok "UFW active"
fi

# ============ BƯỚC 5: NODE.JS + NPM + PM2 ============
log_step "Bước 5/13: Node.js $NODE_VERSION + pm2"

if command -v node &> /dev/null; then
  CURRENT_NODE=$(node --version | grep -oP '\d+' | head -1)
  if [ "$CURRENT_NODE" = "$NODE_VERSION" ]; then
    log_ok "Node.js $(node --version) đã cài"
  else
    log_warn "Node.js version cũ: $(node --version). Cần $NODE_VERSION."
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

# ============ BƯỚC 6: GO ============
log_step "Bước 6/13: Go $GO_VERSION"

GO_BIN="/usr/local/go/bin/go"
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

if [ "${INSTALL_GO:-0}" = "1" ]; then
  log_action "Tải Go $GO_VERSION..."
  cd /tmp
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  log_action "Cài Go..."
  tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
  rm -f "go${GO_VERSION}.linux-amd64.tar.gz"
  log_ok "Go $(/usr/local/go/bin/go version)"
fi

# Thêm Go vào PATH (cho user thật, không phải root)
BASHRC="$REAL_HOME/.bashrc"
if ! grep -q "/usr/local/go/bin" "$BASHRC" 2>/dev/null; then
  echo 'export PATH=$PATH:/usr/local/go/bin' >> "$BASHRC"
  log_ok "Đã thêm Go vào PATH ($BASHRC)"
fi

# Cho session hiện tại
export PATH=$PATH:/usr/local/go/bin

# ============ BƯỚC 7: TAILSCALE (OPTIONAL) ============
log_step "Bước 7/13: Tailscale (mesh VPN)"

if command -v tailscale &> /dev/null; then
  log_ok "Tailscale đã cài: $(tailscale version | head -1)"
else
  if ask_yn "Cài Tailscale (mesh VPN giữa các VPS)?" "n"; then
    curl -fsSL https://tailscale.com/install.sh | sh
    log_warn "Sau bootstrap xong, chạy 'tailscale up' và login để kết nối."
  else
    log_info "Bỏ qua Tailscale"
  fi
fi

# ============ BƯỚC 8: CLONE SERVICES ============
log_step "Bước 8/13: Clone $(grep -cv '^#\|^$' "$SERVICES_LIST") services"

mkdir -p "$SERVICES_DIR"
chown "$REAL_USER:$REAL_USER" "$SERVICES_DIR"

while IFS='|' read -r repo pm2_name service_type; do
  # Skip comment và dòng rỗng
  [[ "$repo" =~ ^#.*$ || -z "$repo" ]] && continue

  SERVICE_PATH="$SERVICES_DIR/$repo"
  REPO_URL="https://github.com/$GITHUB_USER/$repo.git"

  if [ -d "$SERVICE_PATH/.git" ]; then
    log_ok "$repo đã clone, pull mới nhất..."
    cd "$SERVICE_PATH"
    sudo -u "$REAL_USER" git pull origin master 2>/dev/null || sudo -u "$REAL_USER" git pull origin main 2>/dev/null || log_warn "Pull $repo thất bại"
  else
    log_action "Clone $repo..."
    sudo -u "$REAL_USER" git clone "$REPO_URL" "$SERVICE_PATH" || {
      log_error "Clone $repo fail. URL: $REPO_URL"
      continue
    }
    log_ok "Cloned $repo"
  fi
done < "$SERVICES_LIST"

# ============ BƯỚC 9: TẠO .ENV CHO TỪNG SERVICE ============
log_step "Bước 9/13: Tạo .env cho từng service"

log_warn "Sẽ mở nano cho từng service để bạn điền .env"
log_warn "Có $(grep -cv '^#\|^$' "$SERVICES_LIST") service. Mỗi service sẽ nano 1 lần."
echo ""
if ! ask_yn "Bắt đầu config .env?"; then
  log_warn "Skip. Bạn cần tự tạo .env cho từng service trước khi build."
else
  while IFS='|' read -r repo pm2_name service_type; do
    [[ "$repo" =~ ^#.*$ || -z "$repo" ]] && continue

    SERVICE_PATH="$SERVICES_DIR/$repo"

    if [ ! -d "$SERVICE_PATH" ]; then
      log_warn "Skip $repo (chưa clone)"
      continue
    fi

    cd "$SERVICE_PATH"

    if [ -f ".env" ]; then
      log_ok "$repo/.env đã tồn tại"
      if ask_yn "Sửa lại?" "n"; then
        nano .env
      fi
    elif [ -f ".env.example" ]; then
      cp .env.example .env
      chmod 600 .env
      chown "$REAL_USER:$REAL_USER" .env
      log_warn "Mở nano để điền $repo/.env..."
      sleep 1
      nano .env
    else
      log_warn "$repo không có .env.example, skip"
    fi
  done < "$SERVICES_LIST"
fi

# ============ BƯỚC 10: BUILD NESTJS ============
log_step "Bước 10/13: Build 11 NestJS services"

while IFS='|' read -r repo pm2_name service_type; do
  [[ "$repo" =~ ^#.*$ || -z "$repo" ]] && continue
  [ "$service_type" != "nestjs" ] && continue

  SERVICE_PATH="$SERVICES_DIR/$repo"
  if [ ! -d "$SERVICE_PATH" ]; then
    log_warn "Skip $repo (chưa clone)"
    continue
  fi

  cd "$SERVICE_PATH"
  log_action "[$repo] npm install..."
  sudo -u "$REAL_USER" npm install --silent

  log_action "[$repo] npm run build..."
  sudo -u "$REAL_USER" npm run build

  if [ ! -f "dist/src/main.js" ]; then
    log_error "[$repo] Build fail, không thấy dist/src/main.js"
    continue
  fi
  log_ok "[$repo] Build OK"
done < "$SERVICES_LIST"

# ============ BƯỚC 11: BUILD GO ============
log_step "Bước 11/13: Build Go services"

while IFS='|' read -r repo pm2_name service_type; do
  [[ "$repo" =~ ^#.*$ || -z "$repo" ]] && continue
  [ "$service_type" != "go" ] && continue

  SERVICE_PATH="$SERVICES_DIR/$repo"
  if [ ! -d "$SERVICE_PATH" ]; then
    log_warn "Skip $repo (chưa clone)"
    continue
  fi

  cd "$SERVICE_PATH"
  log_action "[$repo] go build..."
  sudo -u "$REAL_USER" -i bash -c "
    export PATH=\$PATH:/usr/local/go/bin
    cd $SERVICE_PATH
    go build -o $pm2_name ./cmd/api/main.go
  "

  if [ ! -f "$pm2_name" ]; then
    log_error "[$repo] Build fail, không thấy binary $pm2_name"
    continue
  fi
  chmod +x "$pm2_name"
  log_ok "[$repo] Build OK"
done < "$SERVICES_LIST"

# ============ BƯỚC 12: PM2 START ============
log_step "Bước 12/13: PM2 start tất cả services"

# Chạy pm2 với user thật, không phải root
while IFS='|' read -r repo pm2_name service_type; do
  [[ "$repo" =~ ^#.*$ || -z "$repo" ]] && continue

  SERVICE_PATH="$SERVICES_DIR/$repo"

  # Check service đã chạy chưa
  if sudo -u "$REAL_USER" pm2 list 2>/dev/null | grep -q "$pm2_name"; then
    log_warn "[$pm2_name] đang chạy, restart..."
    sudo -u "$REAL_USER" pm2 restart "$pm2_name" --update-env
  else
    if [ "$service_type" = "nestjs" ]; then
      log_action "[$pm2_name] pm2 start NestJS..."
      sudo -u "$REAL_USER" pm2 start "$SERVICE_PATH/dist/src/main.js" \
        --name "$pm2_name" \
        -i max \
        --cwd "$SERVICE_PATH"
    elif [ "$service_type" = "go" ]; then
      log_action "[$pm2_name] pm2 start Go..."
      sudo -u "$REAL_USER" pm2 start "$SERVICE_PATH/$pm2_name" \
        --name "$pm2_name" \
        -i max \
        --cwd "$SERVICE_PATH"
    fi
  fi
done < "$SERVICES_LIST"

# ============ BƯỚC 13: PM2 SAVE + STARTUP ============
log_step "Bước 13/13: PM2 save + startup"

sudo -u "$REAL_USER" pm2 save

log_action "Setup PM2 startup (tự bật khi reboot)..."
PM2_STARTUP_CMD=$(sudo -u "$REAL_USER" pm2 startup systemd -u "$REAL_USER" --hp "$REAL_HOME" | grep "sudo env" || echo "")

if [ -n "$PM2_STARTUP_CMD" ]; then
  eval "$PM2_STARTUP_CMD"
  log_ok "Đã setup PM2 startup"
else
  log_warn "PM2 startup có thể đã setup từ trước, hoặc bạn cần chạy thủ công:"
  log_info "  pm2 startup"
fi

# ============ HOÀN TẤT ============
echo ""
echo ""
cat <<EOF
${GREEN}╔══════════════════════════════════════════════════════════╗
║                                                          ║
║              ✓ BOOTSTRAP APP HOÀN TẤT                    ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝${NC}

${BLUE}Đã setup:${NC}
  ✓ Tool cơ bản + timezone + swap
  ✓ UFW (22, 80, 443)
  ✓ Node.js $(node --version 2>/dev/null || echo $NODE_VERSION) + pm2
  ✓ Go $GO_VERSION
  ✓ Clone $(grep -cv '^#\|^$' "$SERVICES_LIST") services
  ✓ .env cho từng service
  ✓ Build NestJS + Go
  ✓ PM2 start tất cả với -i max
  ✓ PM2 startup (auto restart khi reboot)

${BLUE}Trạng thái services:${NC}
EOF
sudo -u "$REAL_USER" pm2 list

cat <<EOF

${BLUE}Các lệnh hữu ích:${NC}

  ${YELLOW}pm2 list${NC}                       — Xem trạng thái tất cả services
  ${YELLOW}pm2 logs <service-name>${NC}        — Xem log 1 service
  ${YELLOW}pm2 restart <service-name>${NC}     — Restart 1 service
  ${YELLOW}pm2 monit${NC}                      — Dashboard real-time

${BLUE}Update code:${NC}

  ${YELLOW}cd $SERVICES_DIR/<repo>${NC}
  ${YELLOW}git pull${NC}
  ${YELLOW}npm install && npm run build${NC}    # NestJS
  ${YELLOW}go build -o <name> ./cmd/api/main.go${NC}  # Go
  ${YELLOW}pm2 restart <service-name>${NC}

${YELLOW}LƯU Ý:${NC}
  - Nếu cài Tailscale: chạy 'tailscale up' và login
  - PM2 dashboard online: pm2 link <secret> <public> (https://app.pm2.io)
  - Log files: ~/.pm2/logs/

EOF

log_ok "Xong. VPS App đã sẵn sàng."