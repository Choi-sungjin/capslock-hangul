# Caps Lock 한영 전환

Caps Lock을 짧게 누르면 한영 전환, 길게 누르면 대문자 고정. 기존 한영키 자리는 오른쪽 Alt로 사용합니다.

| 플랫폼 | 상태 |
| --- | --- |
| [Linux](linux/README.md) | 구현 및 Ubuntu 24.04 GNOME X11 / IBus 한글 환경에서 설치·재부팅 검증 |
| [Windows](windows/README.md) | 개발 예정, 아직 구현·검증하지 않음 |

## 공통 동작

- Caps Lock 단독 입력: 300ms 미만이면 한영 전환, 300ms 이상이면 Caps Lock 켜기/끄기.
- 300ms 전에 다른 키를 누르면 즉시 한영 전환으로 확정하고 그 키를 전달합니다.
- 기존 전용 한영키와 오른쪽 Alt 위치는 오른쪽 Alt로 사용합니다.
- 운영체제 시작 뒤 별도 실행 없이 사용할 수 있도록 자동 시작을 구성합니다.

macOS와 비슷한 사용감을 목표로 합니다. 300ms 및 겹쳐 누르기 정책은 이 프로젝트의 명세이며 macOS 내부 동작과 완전히 같다고 주장하지 않습니다.

Linux 구현은 [keyd v2.6.0](https://github.com/rvaiya/keyd/tree/v2.6.0)을 기반으로 하며, 아주 빠른 탭 처리에 필요한 패치를 포함합니다. 원본 저작권과 라이선스는 [LICENSE-keyd](linux/LICENSE-keyd)에 보존합니다.

개인 설정 백업, 실행 로그, 빌드된 바이너리는 Git에 포함하지 않습니다. 설치 전에 로컬에서 빌드하세요.
