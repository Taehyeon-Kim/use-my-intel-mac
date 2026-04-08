#!/bin/bash
set -e

# ============================================================
# Intel Mac 24/7 Remote Dev Server Setup
# - Tailscale + SSH (key-only) + Firewall + tmux + Claude Code
# - 원격에서 Claude Code 세션을 실행/유지하는 환경 구축
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()  { echo -e "\n${GREEN}━━━ $1 ━━━${NC}"; }

# --- Pre-checks ---
[[ "$(uname)" == "Darwin" ]] || error "macOS 전용 스크립트입니다."
[[ "$(uname -m)" == "x86_64" ]] || warn "Intel Mac이 아닙니다. 계속 진행합니다."

step "1/7 Homebrew"
if ! command -v brew &>/dev/null; then
  echo "Homebrew를 설치합니다. 공식 설치 스크립트를 사용합니다."
  echo "검증: https://github.com/Homebrew/install"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/usr/local/bin/brew shellenv)"
  echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
  info "Homebrew 설치 완료"
else
  info "Homebrew 이미 설치됨"
fi

step "2/7 핵심 패키지 설치"
brew install tmux node tailscale
sudo brew services start tailscale
info "tmux, node, tailscale 설치 완료 (tailscale 데몬 시작됨)"

step "3/7 Claude Code 설치"
if ! command -v claude &>/dev/null; then
  npm install -g @anthropic-ai/claude-code
  info "Claude Code 설치 완료"
else
  info "Claude Code 이미 설치됨 ($(claude --version 2>/dev/null || echo 'installed'))"
fi

step "4/9 크롤링 환경 (Python + Playwright)"
brew install pyenv
# pyenv 초기화
if ! grep -q 'eval "$(pyenv init -)"' ~/.zprofile 2>/dev/null; then
  cat >> ~/.zprofile << 'PYENV'
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
PYENV
fi
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

# Python 3.12 설치
PYTHON_VERSION="3.12"
if ! pyenv versions | grep -q "$PYTHON_VERSION"; then
  pyenv install "$PYTHON_VERSION"
fi
pyenv global "$PYTHON_VERSION"
info "Python $PYTHON_VERSION 설치 완료"

# 크롤링용 venv
CRAWL_DIR="$HOME/crawl"
mkdir -p "$CRAWL_DIR"
python -m venv "$CRAWL_DIR/.venv"
source "$CRAWL_DIR/.venv/bin/activate"
pip install --upgrade pip
pip install playwright httpx beautifulsoup4 lxml
playwright install chromium
deactivate
info "크롤링 환경 구성 완료 ($CRAWL_DIR/.venv)"

step "5/9 전원 / 잠자기 설정"
sudo pmset -a sleep 0 displaysleep 0 disksleep 0
sudo pmset -a autorestart 1
sudo pmset -a powernap 0
sudo pmset -a womp 1          # Wake on LAN
info "잠자기 비활성화 + 자동 재시작 설정 완료"

if pmset -g | grep -q "highstandbythreshold"; then
  warn "배터리 충전 관리는 AlDente 앱 설치를 권장합니다 (80% 제한)"
fi

step "6/9 SSH 활성화 + 보안 강화"
# SSH 활성화
if ! sudo systemsetup -getremotelogin | grep -q "On"; then
  sudo systemsetup -setremotelogin on
  info "SSH(Remote Login) 활성화 완료"
else
  info "SSH 이미 활성화됨"
fi

# SSH 키 생성 (없는 경우)
if [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "intel-mac-server"
  info "SSH 키 생성 완료: ~/.ssh/id_ed25519.pub"
fi

# authorized_keys 준비
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# SSH 보안 강화: 비밀번호 인증 비활성화, 키 인증만 허용
SSHD_CONFIG="/etc/ssh/sshd_config"
sudo cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d)"

apply_ssh_setting() {
  local key="$1" value="$2"
  if sudo grep -q "^${key}" "$SSHD_CONFIG"; then
    sudo sed -i '' "s/^${key}.*/${key} ${value}/" "$SSHD_CONFIG"
  elif sudo grep -q "^#${key}" "$SSHD_CONFIG"; then
    sudo sed -i '' "s/^#${key}.*/${key} ${value}/" "$SSHD_CONFIG"
  else
    echo "${key} ${value}" | sudo tee -a "$SSHD_CONFIG" >/dev/null
  fi
}

apply_ssh_setting "PasswordAuthentication" "no"
apply_ssh_setting "KbdInteractiveAuthentication" "no"
apply_ssh_setting "UsePAM" "no"
apply_ssh_setting "PermitRootLogin" "no"
apply_ssh_setting "MaxAuthTries" "3"
apply_ssh_setting "ClientAliveInterval" "120"
apply_ssh_setting "ClientAliveCountMax" "3"

# sshd 설정 검증
if sudo sshd -t 2>/dev/null; then
  sudo launchctl stop com.openssh.sshd 2>/dev/null || true
  sudo launchctl start com.openssh.sshd 2>/dev/null || true
  info "SSH 보안 강화 완료 (비밀번호 인증 비활성화, 키 인증만 허용)"
else
  warn "SSH 설정 검증 실패. 백업에서 복원합니다."
  sudo cp "${SSHD_CONFIG}.backup."* "$SSHD_CONFIG"
fi

step "7/9 방화벽 설정"
# macOS 기본 방화벽 활성화
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
info "방화벽 활성화 + 스텔스 모드 설정 완료"

step "8/9 tmux 설정 + 편의 스크립트"

cat > ~/.tmux.conf << 'TMUX'
set -g mouse on
set -g history-limit 50000
set -g default-terminal "screen-256color"
set -g destroy-unattached off
set -g exit-unattached off
set -g status-right '#H | %Y-%m-%d %H:%M'
TMUX
info "tmux 설정 완료"

mkdir -p ~/bin
cat > ~/bin/ccs << 'SCRIPT'
#!/bin/bash
# ccs - Claude Code tmux 세션 매니저
# 사용법:
#   ccs            → 기본 세션 접속 (없으면 생성)
#   ccs work       → 'work' 세션 접속
#   ccs ls         → 세션 목록
#   ccs kill work  → 'work' 세션 종료

SESSION="${1:-claude}"

case "$SESSION" in
  ls|list)
    tmux list-sessions 2>/dev/null || echo "활성 세션 없음"
    ;;
  kill)
    tmux kill-session -t "${2:-claude}" 2>/dev/null && echo "세션 '${2:-claude}' 종료됨"
    ;;
  *)
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      tmux attach -t "$SESSION"
    else
      tmux new-session -s "$SESSION"
    fi
    ;;
esac
SCRIPT
chmod +x ~/bin/ccs

if ! grep -q 'export PATH="$HOME/bin:$PATH"' ~/.zprofile 2>/dev/null; then
  echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zprofile
fi
info "ccs (Claude Code 세션 매니저) 설치 완료"

# 크롤링 편의 스크립트
cat > ~/bin/crawl << 'SCRIPT'
#!/bin/bash
# crawl - 크롤링용 tmux 세션 (venv 자동 활성화)
SESSION="crawl"
CRAWL_DIR="$HOME/crawl"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux attach -t "$SESSION"
else
  tmux new-session -s "$SESSION" -c "$CRAWL_DIR" \
    "source .venv/bin/activate && exec $SHELL"
fi
SCRIPT
chmod +x ~/bin/crawl

step "9/9 SSH 프록시 스크립트"
cat > ~/bin/proxy << 'SCRIPT'
#!/bin/bash
# proxy - 이 맥을 SOCKS5 프록시로 사용 (메인 맥북에서 실행)
# 사용법: ssh -D 1080 -N intel-mac
echo "메인 맥북에서 아래 명령어 실행:"
echo "  ssh -D 1080 -N $(hostname | tr '[:upper:]' '[:lower:]')"
echo ""
echo "크롤러에서 프록시 설정:"
echo '  proxies = {"http": "socks5://localhost:1080", "https": "socks5://localhost:1080"}'
SCRIPT
chmod +x ~/bin/proxy
info "crawl, proxy 스크립트 설치 완료"

# --- 완료 안내 ---
echo ""
echo -e "${GREEN}━━━ 설치 완료 ━━━${NC}"
echo ""
echo -e "${YELLOW}중요: SSH 키 등록을 먼저 해야 원격 접속이 가능합니다!${NC}"
echo ""
echo "  메인 맥북에서 실행:"
echo "    ssh-copy-id $(whoami)@<이-맥북-IP>"
echo "  또는 직접 복사:"
echo "    cat ~/.ssh/id_ed25519.pub  # 메인 맥북에서"
echo "    # 이 맥북의 ~/.ssh/authorized_keys 에 붙여넣기"
echo ""
echo "남은 수동 작업:"
echo ""
echo "  1. Tailscale 로그인 (한 번만):"
echo "     tailscale up"
echo ""
echo "  2. 메인 맥북/모바일에도 Tailscale 설치 후 같은 계정 로그인"
echo ""
echo "  3. 원격 접속 테스트:"
echo "     ssh $(whoami)@<tailscale-hostname>"
echo ""
echo "사용법:"
echo "  ccs          → Claude Code용 tmux 세션 열기"
echo "  ccs work     → 'work' 이름으로 세션 열기"
echo "  ccs ls       → 세션 목록 보기"
echo "  claude      → Claude Code 실행"
echo ""
echo "  Ctrl+B, D   → tmux 세션에서 빠져나오기 (세션 유지됨)"
echo ""
