# use-my-intel-mac

남는 Intel MacBook을 24/7 원격 개발 서버로 세팅하는 스크립트.

SSH + Tailscale로 어디서든 접속해서 Claude Code, 크롤링 등을 실행할 수 있는 환경을 구축합니다.

## 설치 항목

- **Homebrew** + tmux, node, tailscale
- **Claude Code** CLI
- **Python 3.12** (pyenv) + Playwright, httpx, beautifulsoup4
- **전원 관리** — 잠자기 비활성화, 자동 재시작
- **SSH** — 키 인증만 허용, 비밀번호 인증 비활성화
- **방화벽** — macOS 방화벽 + 스텔스 모드
- **cc / crawl / proxy** 편의 명령어

## Step 1. 인텔 맥북에서 설치

```bash
git clone https://github.com/Taehyeon-Kim/use-my-intel-mac.git
cd use-my-intel-mac
chmod +x setup.sh
./setup.sh
```

## Step 2. [인텔 맥북] Tailscale 로그인

```bash
# Tailscale 데몬 시작 (brew 설치 시 필수)
sudo brew services start tailscale

# 로그인 — 브라우저가 열리면 Google/GitHub 계정으로 로그인
tailscale up

# 호스트명 확인 — 이 이름을 메인 맥북에서 사용
tailscale status
# 예시 출력:
#   100.x.x.x   tony-intel-mac   ...
#                ^^^^^^^^^^^^^^ 이 호스트명을 기억
```

## Step 3. [메인 맥북] Tailscale 설치 + SSH 키 등록

```bash
# 1. Tailscale 설치 + 같은 계정으로 로그인
brew install tailscale
sudo brew services start tailscale
tailscale up

# 2. 인텔 맥 호스트명/IP 확인 (같은 계정이면 어디서든 조회 가능)
tailscale status
```

### SSH 키 등록

setup.sh가 비밀번호 인증을 꺼놓으므로, 키 등록을 위해 임시로 켜야 합니다.

```bash
# [인텔 맥북] 비밀번호 인증 임시 활성화
sudo sed -i '' 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo launchctl stop com.openssh.sshd && sudo launchctl start com.openssh.sshd
```

```bash
# [메인 맥북] SSH 키 등록
ssh-copy-id <user>@<인텔맥-IP>
# 예: ssh-copy-id tony@100.x.x.x
```

```bash
# [인텔 맥북] 비밀번호 인증 다시 비활성화
sudo sed -i '' 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo launchctl stop com.openssh.sshd && sudo launchctl start com.openssh.sshd
```

```bash
# [메인 맥북] 접속 테스트
ssh <user>@<인텔맥-IP>
# 예: ssh tony@100.x.x.x
```

모바일(iOS)에서는 Tailscale 앱 + Blink Shell 또는 Termius로 접속.

## 사용법

### Claude Code 세션

```bash
cc              # 기본 세션 열기 (없으면 생성)
cc work         # 'work' 이름으로 세션 열기
cc ls           # 세션 목록
cc kill work    # 세션 종료
claude          # Claude Code 실행
Ctrl+B, D       # 세션에서 빠져나오기 (세션 유지됨)
```

### 크롤링

```bash
crawl           # 크롤링용 tmux 세션 (venv 자동 활성화)
python my_crawler.py
Ctrl+B, D       # 빠져나와도 크롤러 계속 실행
```

크롤링 스크립트는 `~/crawl/` 디렉토리에 넣으면 됩니다.

### SOCKS5 프록시 (메인 맥북에서 인텔 맥 IP로 크롤링)

```bash
# 메인 맥북에서 실행
ssh -D 1080 -N <인텔맥-tailscale-호스트명>

# 크롤러에서 프록시 설정
proxies = {"http": "socks5://localhost:1080", "https": "socks5://localhost:1080"}
```

가정용 ISP(residential) IP로 요청이 나가므로 클라우드 IP 대비 차단율이 낮습니다.

## 보안

- SSH 비밀번호 인증 비활성화 (키 인증만)
- root 로그인 차단
- MaxAuthTries 3회 제한
- macOS 방화벽 + 스텔스 모드 활성화
- Tailscale을 통한 네트워크 접근 제어
