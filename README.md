# Caps Lock 한영 전환

Caps Lock을 짧게 누르면 한영 전환, 길게 누르면 대문자 고정. 기존 한영키 자리는 오른쪽 Alt로 사용합니다.

| 플랫폼 | 상태 |
| --- | --- |
| [Linux](linux/README.md) | 구현 및 Ubuntu 24.04 GNOME X11 / IBus 한글 환경에서 설치·재부팅 검증 |
| [Windows](windows/README.md) | 네이티브 구현, Windows 11에서 설치·재부팅 후 로그인 자동 시작·실제 키 입력 확인 |

## Windows PC에서 사용하기

저장소를 받은 뒤 `windows` 폴더에서 일반 PowerShell로 실행합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Windows에 포함된 .NET Framework로 빌드하고 현재 사용자에게 설치합니다. 설치 즉시 실행되며, 이후에는 재부팅 후 Windows 로그인 직후 자동 실행됩니다. WSL이나 AutoHotkey는 필요하지 않습니다.

[Windows 설치 안내](windows/README.md)에 키 동작, 설치 위치, 상태 확인, 제거 방법과 전용 한영키 옵션을 정리했습니다.

## 다른 Linux PC에서 사용하기

**소스를 받은 뒤 그 PC에서 빌드·설치해야 합니다.** 압축 해제만으로 바로 실행되는 배포 파일은 아닙니다. 설치하면 부팅 자동 시작도 등록됩니다.

검증된 환경은 **Ubuntu 24.04 + GNOME X11 + IBus 한글**입니다. 다른 배포판, KDE, Wayland, Fcitx 조합은 추가 확인이 필요합니다. 현재 저장소가 비공개이므로 내려받을 계정에 접근 권한이 있어야 합니다.

[Linux 설치 안내](linux/README.md)에 패키지 준비, Git/ZIP 다운로드, 빌드·설치, 재부팅 확인, 제거·복원 순서를 정리했습니다.

## 공통 동작

- Caps Lock 단독 입력: 300ms 미만이면 한영 전환, 300ms 이상이면 Caps Lock 켜기/끄기.
- 300ms 전에 다른 키를 누르면 즉시 한영 전환으로 확정하고 그 키를 전달합니다.
- 기존 전용 한영키와 오른쪽 Alt 위치는 오른쪽 Alt로 사용합니다.
- Linux는 부팅 시, Windows는 사용자 로그인 직후 별도 실행 없이 사용할 수 있도록 자동 시작을 구성합니다.

macOS와 비슷한 사용감을 목표로 합니다. 300ms 및 겹쳐 누르기 정책은 이 프로젝트의 명세이며 macOS 내부 동작과 완전히 같다고 주장하지 않습니다.

Linux 구현은 [keyd v2.6.0](https://github.com/rvaiya/keyd/tree/v2.6.0)을 기반으로 하며, 아주 빠른 탭 처리에 필요한 패치를 포함합니다. 원본 저작권과 라이선스는 [LICENSE-keyd](linux/LICENSE-keyd)에 보존합니다.

개인 설정 백업, 실행 로그, 빌드된 바이너리는 Git에 포함하지 않습니다. 설치 전에 로컬에서 빌드하세요.
