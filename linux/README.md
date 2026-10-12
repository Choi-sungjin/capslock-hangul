# Linux 설치 및 검증

## 확인된 환경

Ubuntu 24.04, GNOME X11, IBus 한글 입력기. 실제 설치와 사용자 입력, 재부팅 후 자동 시작 및 설정 유지를 확인했습니다. 다른 배포판·Wayland·입력기 조합은 이 저장소에서 검증하지 않았습니다.

## 준비 및 빌드

Ubuntu 기준 빌드 도구는 `git`, `build-essential`, `patch`가 필요합니다. 설치 스크립트는 systemd를 전제로 합니다. 데스크톱 설정에는 GNOME과 `ibus-hangul`, Python 3, gsettings가 필요합니다.

```bash
git clone https://github.com/Choi-sungjin/-.git capslock
cd capslock/linux
./dev/build-payload.sh
```

빌드는 keyd v2.6.0을 `.work/keyd`에 내려받고, 커밋 `7c0aecb8bfd34dc8642bf4eefd2e59c89e61cec3`과 일치하는지 확인한 뒤 패치를 적용합니다. 결과는 `payload/`에 생성됩니다. `WORK`는 임시 작업 디렉터리, `KEYD_GIT`는 이미 받은 keyd 저장소 경로로 지정할 수 있습니다. 실행 파일은 설치할 PC에서 빌드하세요.

## 설치

```bash
sudo ./install.sh --check
sudo ./install.sh
./user-settings/apply-user-settings.sh --dry-run
./user-settings/apply-user-settings.sh
```

서비스를 먼저 설치한 뒤 사용자 설정을 적용하세요. 사용자 설정 명령은 **sudo 없이** 실행합니다. keyd와 다른 키 리매핑 서비스가 있으면 설치가 충돌을 감지하고 중단합니다.

- 시스템 서비스: `keyd-capslock.service`, 부팅 시 로그인 화면보다 먼저 시작하도록 등록.
- 실행 파일: `/usr/local/bin/keyd-capslock`.
- 설정: `/etc/keyd-capslock/default.conf`.
- 입력기: 오른쪽 Alt의 한영 역할을 제거하고 `Hangul` 및 기존 다른 전환 키를 유지.
- 최초 사용자 설정: `user-settings/backup/original-user-settings.tsv`에 한 번만 백업.

적용 직후 반영되지 않는 앱은 로그아웃 후 다시 로그인하세요. 이후 실행은 이 저장소 폴더에 의존하지 않습니다. 사용자 설정은 로그인한 계정에 적용되며 로그인 화면의 입력기 설정은 별개입니다.

```bash
systemctl is-active keyd-capslock.service   # active
systemctl is-enabled keyd-capslock.service # enabled
journalctl -b -u keyd-capslock.service
```

Caps Lock 짧게/길게, 기존 한영키 위치, Alt+문자 단축키를 확인하고 재부팅 후에도 다시 확인하세요. USB/Bluetooth 재연결과 모든 앱 조합은 별도 실제 시험이 필요합니다.

## 동작과 주의점

- 단독 탭 <300ms: `Hangul` 키. 단독 길게 누르기 ≥300ms: Caps Lock.
- 300ms 전 다른 키: 한영 전환으로 확정. 이후 계속 누르고 있어도 Caps Lock으로 바뀌지 않습니다.
- 전용 한영키: 오른쪽 Alt. Caps Lock에서 생성한 Hangul 신호는 다시 매핑하지 않습니다.
- `[ids] *`이므로 keyd가 인식한 모든 키보드에 적용됩니다.
- Shift/Ctrl과 함께 탭하면 조합된 Hangul 키가 전달됩니다. 입력기별 전환은 별도 확인이 필요합니다.
- 서비스는 비정상 종료 시 2초 뒤 다시 시작하도록 설정됩니다.
- 비상 키 `Backspace+Esc+Enter`는 keyd를 종료합니다. 복구 중에는 `sudo systemctl stop keyd-capslock`으로 서비스를 멈추세요.

## 검사

전체 검사는 일반 사용자로 실행합니다. Ubuntu에서는 추가로 `python3-gi`, `gir1.2-ibus-1.0`, `ibus`, `ibus-hangul`, `dconf-cli`, `x11-xkb-utils`, `xkb-data`, `file`, `binutils`, `util-linux`, `systemd`가 필요합니다. 데스크톱 환경 시험이므로 최소 컨테이너에서 전부 실행된다고 보장하지 않습니다.

```bash
./dev/run-all-tests.sh
```

키 입력 경계·동시 입력·반복, 원본 keyd 회귀 검사, 설치 실패 복원, 격리된 사용자 설정·XKB·IBus를 검사합니다. 일부 단계는 의도적으로 실패해야 통과합니다. 마지막 `steps not as expected: 0`을 확인하세요. 선택적 IBus 시험이 `SKIP`이면 해당 검사는 실행되지 않은 것입니다. 생성되는 로그는 `logs/`에 있으며 개인 환경 정보가 포함될 수 있어 Git에서 제외합니다. 테스트는 실제 서비스를 설치하거나 데스크톱에 키 입력을 보내지 않습니다.

## 제거와 복원

```bash
./user-settings/restore-user-settings.sh --dry-run
./user-settings/restore-user-settings.sh
sudo ./uninstall.sh
```

복원은 최초 백업된 네 설정의 **값 전체**를 되돌립니다. 설치 후 별도로 바꾼 해당 설정도 덮어쓰므로 dry-run을 먼저 확인하세요. 시스템 제거는 이 설치기가 만든 파일만 처리하며 사용자가 고친 설정은 보존합니다.

## 소스

`keyd-capslock.patch`는 `timeout_instant_tap` 옵션을 추가합니다. 같은 밀리초에 눌렸다 떼어진 단독 탭을 길게 누르기로 오판하는 경우를 보정합니다. 기본값은 꺼짐이며 이 프로젝트 설정에서만 켭니다. 원본 keyd 라이선스는 `LICENSE-keyd`를 확인하세요.
