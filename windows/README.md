# Windows 설치 및 사용

Windows용 네이티브 트레이 프로그램입니다. WSL이나 AutoHotkey 없이 Windows에 포함된 .NET Framework로 빌드합니다.

| 키 입력 | 동작 |
| --- | --- |
| Caps Lock 단독, 300ms 미만 | 선택된 한국어 Microsoft IME의 한영 전환 |
| Caps Lock 300ms 이상 | Caps Lock 켜기/끄기, 누른 동안 한 번만 처리 |
| 300ms 전에 다른 키 누름 | 한영 전환을 먼저 적용한 뒤 그 키 전달 |
| 한국어 배열의 오른쪽 Alt 위치 | 실제 오른쪽 Alt로 사용 |
| 별도 전용 한영키 | 기본값은 오른쪽 Alt 한 번 누르기; 유지 모드는 아래 참고 |

Linux와 사용자 동작을 맞추되 Windows에서는 한영/Caps 출력에 짧은 down/up 쌍을 사용합니다. Linux의 키 이벤트 스트림과 완전히 같지는 않습니다.

## 설치

이 저장소의 `windows` 폴더에서 일반 PowerShell로 실행합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

빌드와 자동 검사를 먼저 수행한 뒤 다음을 설정합니다.

- 실행 파일과 관리 스크립트: Windows **문서 폴더 아래 `CapsLockHangul`**. 문서 폴더는 `[Environment]::GetFolderPath('MyDocuments')`로 확인하므로 사용자 지정 위치도 반영합니다.
- 자동 시작: 현재 계정의 로그인 작업 `CapsLockHangul-<사용자 SID>`
- 로그인 지연 없음, 배터리 사용 중에도 실행, 실행 시간 제한 없음
- 비정상 종료 시 1분 간격으로 최대 3회 다시 시작
- 설치 즉시 실행하고 준비 완료 상태 확인

**재부팅 후 Windows 로그인 직후 자동으로 실행됩니다.** 이후 실행은 저장소 폴더에 의존하지 않습니다. 로그인 전 화면, 잠금 화면, UAC 보안 화면은 지원 범위가 아닙니다. 일반 권한으로 실행하므로 관리자 권한 앱으로의 키 주입도 지원하지 않습니다.

설치기는 Windows의 한국어 배열이나 다른 프로그램의 키 설정을 바꾸지 않습니다. 한국어 Microsoft IME를 선택한 상태에서 사용하세요. ENG 입력기에서 한국어 입력기 선택까지 자동으로 바꾸지는 않습니다.

같은 설치 명령을 다시 실행하면 프로그램을 정상 종료한 뒤 업데이트합니다. 설치 실패 시 이전 파일과 시작 설정 복원을 시도합니다. 기존 폴더·작업이 다른 프로그램의 것으로 보이면 덮어쓰지 않고 중단합니다.

작업 스케줄러 등록을 정책이 막는 PC에서만 다음 대안을 사용할 수 있습니다. 이 경우 자동 시작은 HKCU Run 방식이며 작업 스케줄러의 장애 재시작 기능은 없습니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -AllowRunKeyFallback
```

## 상태 확인, 중지, 다시 시작

설치 후 어느 폴더에서든 실행할 수 있습니다. 트레이의 파란색 `한` 아이콘 메뉴에서도 상태 확인과 종료가 가능합니다.

```powershell
$caps = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CapsLockHangul'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$caps\status.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$caps\stop.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$caps\start.ps1"
```

`status.ps1`은 준비 완료이면 종료 코드 0, 중지 상태면 3, 시작·종료 진행 중이면 4, 오류·미설치이면 1을 반환합니다. 프로그램이 실제로 준비되었는지 확인하며, 자동 시작 작업의 등록 상태도 함께 표시합니다.

로그는 같은 설치 폴더의 `logs` 하위 폴더(`$caps\logs`)에 있습니다. 시작·종료·오류를 기록하며 사용자가 입력한 일반 문자 내용은 기록하지 않습니다.

## 전용 한영키를 길게 눌러 Alt 조합으로 쓰기

오른쪽 Alt 위치의 키는 기본 설치로 누름/해제를 유지합니다. 별도 전용 한영키는 키보드에 따라 해제 이벤트를 보내지 않아, 기본값으로 안전한 Alt 한 번 누르기를 사용합니다.

전용 키가 **누름과 해제 이벤트를 모두 보내는 하드웨어라는 것이 확인된 경우에만** 유지 모드를 켭니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DedicatedHangulHold
```

이 옵션은 자동 시작에도 저장되며 일반 재설치 시 유지됩니다. 기본값으로 되돌리는 명령은 다음과 같습니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DedicatedHangulPulse
```

해제 이벤트가 없는 전용 키에서는 정확한 누르기 유지 기능을 재현할 수 없습니다. Alt가 붙어 있으면 트레이에서 종료하거나 `stop.ps1`로 중지하고 기본값으로 되돌리세요.

## 검증

2026-10-13 Windows 11 Pro의 한국어 Microsoft IME 환경에서 설치와 실제 키 입력을 확인했습니다. 사용자가 PC를 재부팅한 뒤에도 로그인 자동 실행과 키 동작이 정상임을 확인했고, 프로그램 로그와 실행 상태로 재부팅 후 시작을 확인했습니다.

- 상태 전이·Win32 구조체 자동 검사: 73개 통과
- 설치 스크립트 회귀검사: PowerShell 5.1과 7에서 각각 41개 통과
- 실제 Windows 후크·SendInput 경로 검사: 18개 통과
- 한국어 IME·오른쪽 Alt 네이티브 입력 확인: 8개 통과
- 설치·중지·자동 실행 작업 재시작·제거·재설치·업데이트 검사: 20개 통과

`windows` 폴더에서 실행합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\dev\Test-Deployment.ps1
```

프로그램의 순수 상태 검사와 Win32 구조체 검사는 다음과 같습니다. 키 입력을 실제 데스크톱에 보내지 않습니다.

```powershell
$p = Start-Process .\bin\CapsLockHangul.exe -ArgumentList '--self-test --report self-test.txt' -WindowStyle Hidden -Wait -PassThru
$p.ExitCode
Get-Content .\self-test.txt
```

실제 키보드 후크·SendInput 경로를 시험하는 별도 검사도 제공합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\dev\Test-HookIntegration.ps1
```

이 검사는 자체 시험창을 잠시 활성화합니다. 실행 중에는 다른 창으로 전환하거나 키를 누르지 마세요. 시험 빌드에서만 고유한 합성 입력 표식을 허용합니다. Caps 상태·Alt 해제·이전 활성 창을 복원합니다.

합성 입력 검사는 실제 키보드의 전용 한영키 신호, 모든 앱의 입력기 동작, 로그인 전 보안 화면, 실제 재부팅 검증을 대신하지 않습니다. 재부팅 후에는 `status.ps1`과 실제 짧은 Caps/긴 Caps/오른쪽 Alt 조합을 확인하세요.

## 제거

```powershell
$caps = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CapsLockHangul'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$caps\uninstall.ps1"
```

정상 종료, 이 도구의 자동 시작 등록 제거, 관리 파일 제거 순서로 처리합니다. 로그는 기본적으로 보존하며 재설치할 수 있도록 소유권 표시도 남깁니다. 다른 파일은 삭제하지 않습니다.

로그까지 지우려면 `-RemoveLogs`를 추가합니다. 운영체제의 키보드 설정을 변경하지 않았으므로 별도 입력기 설정 복원은 필요하지 않습니다.
