# 원격 백업 인터페이스 (cubrid backupdb -> 다른 IP 백업 서버)

`cubrid backupdb` 결과를 다른 IP의 백업 서버로 스트리밍 전송하는 인터페이스.

- 조건1) 네트워크가 가끔 단절해도 재접속/이어받기(resume)로 백업을 정상 완료한다.
- 조건2) 백업 장비가 지정 시간(기본 60초) 이상 문제면 오류 로그를 남기고 backupdb 를 정지한다.

## 구성
| 파일 | 위치 | 역할 |
|------|------|------|
| rbk_listener.c | 백업 서버(수신측) | 재접속/이어받기 지원 수신기. 받은 스트림을 파일에 append |
| rbk_forward.c  | DB 서버(송신측)  | FIFO 스트림을 로컬 spool 로 흡수하며 원격 전송. 순단 이어받기 + 무응답 watchdog |
| remote_backupdb.sh | DB 서버(송신측) | backupdb 를 FIFO 로 띄우고 forward 를 붙이는 오케스트레이터. 조건2 시 backupdb 정지 |

## 동작 원리
```
[DB 서버]                                            [백업 서버]
cubrid backupdb -D FIFO --> (FIFO) --> rbk_forward --TCP--> rbk_listener --> 백업파일
                                        |  로컬 spool 로 먼저 흡수(backupdb 안 막힘 = 커밋 스톨 회피)
                                        |  순단 시 재접속 + offset 이어받기 (조건1)
                                        |  60초 이상 무응답 -> exit 2 (조건2)
                        remote_backupdb.sh 가 exit 2 감지 -> backupdb 정지 + 오류 로그
```
- 이어받기 프로토콜: 접속 시 수신측이 현재 파일 크기(=받은 바이트)를 알려주고, 송신측은 그 지점부터 spool 을 다시 보냄. 마지막에 'F'(완료검증)로 총 크기 일치를 확인.
- spool 은 로컬 디스크에 백업 크기만큼 필요(네트워크와 backupdb 를 분리해 커밋 지연을 막기 위함).

## 사용법
1) 백업 서버(수신측)에서 리스너 실행:
```
gcc -O2 -o rbk_listener rbk_listener.c
./rbk_listener 9099 /backup/demodb_$(date +%Y%m%d).bk /backup/rbk_listener.log
```
2) DB 서버(송신측)에서 전송 실행:
```
REMOTE_IP=192.168.0.100 REMOTE_PORT=9099 DB=demodb LEVEL=0 TIMEOUT=60 \
  bash remote_backupdb.sh
```
- 환경변수: DB, LEVEL(0/1/2), REMOTE_IP, REMOTE_PORT, TIMEOUT(초), SPOOL, LOG, CUBRID_BK_OPT
- cubrid 환경변수($CUBRID 등)와 대상 DB 가 준비되어 있어야 한다.

## 반환코드 (remote_backupdb.sh / rbk_forward)
- 0 : 백업 및 원격 전송 완료
- 2 : 백업 장비 무응답(TIMEOUT 초과) -> backupdb 정지 (조건2)
- 1 : 기타 오류(backupdb 실패, 완료검증 불일치 등)

## 검증 결과 (2026-07-23, 루프백)
- 정상 전송 5MB: 수신 파일 cmp 동일, rc=0
- 조건2: 리스너 없음 + timeout 5초 -> rc=2, 로그 "원격 백업장비 ... 무응답 -> 전송 중단"
- 조건1: 60MB 전송 중 순단 2회 발생 -> 이어받기로 정상 완료, cmp 동일, rc=0
- 참고: transport(forward/listener)는 종단 검증 완료. 실제 cubrid backupdb 연동(대상 DB + 원격 장비)까지의 종단 시험은 운영 환경에서 1회 수행 권장.

## 대안 (더 안전, 스트리밍 대신 로컬 스테이징)
네트워크가 매우 불안정하면 "backupdb 를 로컬에 받은 뒤 rsync 이어받기"가 가장 안전:
```
cubrid backupdb -D /local/bk --no-check demodb
while :; do
  rsync -a --partial --append-verify --timeout=20 /local/bk/ user@REMOTE:/backup/ && break
  # 60초 이상 원격 불가면 중단(별도 watchdog)
done
```
이 방식은 backupdb 가 원격과 무관하게 로컬에서 즉시 완료되어 커밋 스톨 위험이 전혀 없다. 다만 "전송 중 backupdb 정지" 개념은 없다(백업은 이미 로컬에 안전).
