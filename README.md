# CUBRID 원격 백업 툴킷 (cubrid backupdb → 다른 IP 백업 서버)

`cubrid backupdb` 결과를 다른 IP의 백업 서버로 파이프 스트리밍 전송하는 도구.

- 조건1) 네트워크가 가끔 단절해도 재접속/이어받기(resume)로 백업을 정상 완료한다. (방식 A)
- 조건2) 백업 장비가 지정 시간(기본 60초) 이상 문제면 오류 로그를 남기고 backupdb 를 정지한다. (방식 A)

전송 방식은 두 가지다.
- 방식 A (rbk 재개형): FIFO → 로컬 스풀 → TCP → rbk_listener. 이어받기 + 무응답 watchdog + 커밋 지연 회피.
- 방식 B (ssh 스트리밍): FIFO → ssh → 원격 파일. 로컬 공간 불필요, 단순. 자세한 비교는 `백업방식_A_B_비교.md` 참고.

## 배포(설치) 절차 — tar 풀고 설정하기

실서비스에는 배포 tar 하나만 있으면 된다. DB 서버(송신측)와 백업 서버(수신측)에 각각 푼다.

### 1. tar 풀기 (양쪽 서버 공통)
```
tar xzf cubrid_backup_toolkit.tar.gz
cd cubrid_backup_toolkit
```

### 2. 백업 서버(수신측) 설정 — 방식 A를 쓸 때만
```
# 리스너 빌드 (구버전 gcc(4.x)는 -std=gnu99 필요)
gcc -O2 -std=gnu99 -o rbk_listener rbk_listener.c

# 받을 폴더 준비 후 리스너 기동 (포트 예: 9099)
mkdir -p /home/<계정>/db_backupdb
./rbk_listener 9099 /home/<계정>/db_backupdb/<DB>_bk0v000 /home/<계정>/db_backupdb/rbk.log
```
- 전송용 TCP 포트(예: 9099)를 방화벽에서 열어 둔다.
- 리스너는 전송 완료(F 검증) 시 자동 종료되므로, 매 백업마다 다시 기동한다.
- 방식 B만 쓸 경우 이 단계는 필요 없다(ssh 접근만 있으면 됨).

### 3. DB 서버(송신측) 설정
```
# (a) CUBRID 환경변수 (비어 있으면 환경에 맞게 설정)
export CUBRID=/home/<계정>/CUBRID
export CUBRID_DATABASES=$CUBRID/databases
export PATH=$CUBRID/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib

# (b) 방식 A 포워더 빌드 (remote_backupdb.sh 가 자동 빌드하지만 수동도 가능)
gcc -O2 -std=gnu99 -pthread -o rbk_forward rbk_forward.c

# (c) 방식 B(ssh) 또는 리스너 원격 제어용 SSH 키 1회 등록
ssh-keygen -t ed25519 -N '' -f ~/.ssh/bk_key
ssh-copy-id -i ~/.ssh/bk_key.pub <계정>@<BACKUP_IP>   # 최초 1회만 비밀번호 입력
```

### 4. 백업 실행

방식 A (재개형 전송, 권장 — 대용량/불안정망/운영지연 회피):
```
REMOTE_IP=<BACKUP_IP> REMOTE_PORT=9099 DB=<DB> LEVEL=0 TIMEOUT=60 \
  CUBRID_BK_OPT="--no-check" bash remote_backupdb.sh
```
- 환경변수: DB, LEVEL(0/1/2), REMOTE_IP, REMOTE_PORT, TIMEOUT(초), SPOOL, SPOOL_MAX(기본 2G), LOG, CUBRID_BK_OPT
- FIFO/스풀은 실행 시각 suffix 로 유니크 생성되어 반복/동시 실행에도 충돌하지 않는다.
- SPOOL_MAX: 로컬 스풀 최대 크기(예: 2G, 512M, 바이트값). 원격 전송이 백업 생성 속도를 못 따라가 미전송분이 이 한도를 넘으면 오류를 남기고 백업을 종료한다(rc=3).
- 참고: `run_nhidb_A.sh` 는 "리스너 기동 → 포트확인 → 백업 → 결과확인"을 한 번에 하는 예시 래퍼다(대상값은 파일 상단에서 수정).

방식 B (ssh 스트리밍 — 안정·빠른 망, 로컬 공간 부족):
```
FIFO=/tmp/bkfifo_$(date +%s); mkfifo $FIFO
cat $FIFO | ssh -i ~/.ssh/bk_key <계정>@<BACKUP_IP> "cat > /path/<DB>_bk0v000" &
cubrid backupdb -D $FIFO -l 0 --no-check <DB>
rm -f $FIFO
```
- 예시 스크립트 `stream_backup_nhidb.sh` 의 대상 계정/경로/DB만 바꿔 재사용 가능.

### 5. 백업본 검증(복원)
운영 DB 와 무관한 격리 위치로 복원해 DB가 정상적으로 열리는지 확인한다.
```
# 격리 위치로 복원 (restoredb -u -p 로 별도 CUBRID_DATABASES 경로에 복원)
cubrid restoredb -u -p -B <백업디렉터리> <DB>

# 복원된 DB 가 정상적으로 열리는지 standalone 접속으로 확인
csql -S <DBname>

# 자동 검증 스크립트(격리 복원 후 확인)
METHOD=dir BK_DIR=<백업디렉터리> DB=<DB> bash realrun_verify.sh
bash e2e_test.sh
```
- 저장 파일명은 backupdb 기본 규칙 `<DB>_bk0v000`. 복원: `cubrid restoredb -B <백업디렉터리> <DB>`.

## SPOOL_MAX — 로컬 스풀 최대 크기 (중요)

방식 A는 백업 스트림을 로컬 스풀(링 버퍼)에 잠시 담아 원격으로 보낸다. `SPOOL_MAX` 는 이 스풀이 쓸 수 있는 로컬 디스크 최대 크기다. 기본값 2G이며 **환경(백업 크기/디스크 여유/망 속도)에 맞게 조정**한다.

- 로컬 디스크 사용은 `SPOOL_MAX` 를 절대 넘지 않는다(전송된 구간을 링 버퍼로 재사용).
- 원격 전송이 backupdb 생성 속도를 지속적으로 못 따라가 미전송분이 `SPOOL_MAX` 를 넘으면, 오류를 로그에 남기고 백업을 종료한다(rc=3).
- 표기: `2G`, `512M`, `1024K`, 또는 바이트 숫자. 미지정 시 `2G`. 최소 4MB.

```
# 기본 2G
REMOTE_IP=<BACKUP_IP> REMOTE_PORT=9099 DB=<DB> LEVEL=0 bash remote_backupdb.sh

# 스풀 여유를 크게 (대용량/느린 망 대비)
SPOOL_MAX=10G REMOTE_IP=<BACKUP_IP> REMOTE_PORT=9099 DB=<DB> LEVEL=0 bash remote_backupdb.sh

# 로컬 디스크가 빠듯할 때 작게
SPOOL_MAX=512M REMOTE_IP=<BACKUP_IP> REMOTE_PORT=9099 DB=<DB> LEVEL=0 bash remote_backupdb.sh

# 원스텝 래퍼(run_nhidb_A.sh)에도 그대로 전달
SPOOL_MAX=5G bash run_nhidb_A.sh
```
- 초과로 종료되면 로그에 `[오류] 로컬 스풀 최대 크기(...) 초과 ... -> backupdb 정지` 가 남는다. 이때는 `SPOOL_MAX` 를 늘리거나, 망/전송 속도를 점검하거나, backupdb `--sleep-msecs` 로 생성 속도를 늦춘다.
- 실측(2026-07-23): nhidb 약 35GB 전송을 `SPOOL_MAX=2G` 로 완주, 스풀 파일 최대 2G 유지, rc=0.

## backupdb 옵션 전체 예제

파이프 백업은 `cubrid backupdb` 옵션을 대부분 사용할 수 있다. 방식 A는 `-D`(FIFO)/`-l`(LEVEL)을 스크립트가 지정하고 나머지는 `CUBRID_BK_OPT` 로, 방식 B는 명령에 직접 붙인다.

| 옵션 | 의미 | 파이프 백업 |
|------|------|------|
| `-D, --destination-path` | 백업 대상 경로 | 도구가 FIFO로 자동 지정 |
| `-l, --level` (0/1/2) | 백업 레벨(0=full) | 가능(방식 A는 LEVEL 환경변수) |
| `-C, --CS-mode` | 온라인(운영 중) 백업 | 가능(운영 기본/권장) |
| `-S, --SA-mode` | 오프라인 백업 | DB 정지 시에만 |
| `--no-check` | 무결성 검사 생략 | 가능(기본) |
| `-t, --thread-count` | 스레드 수(0=auto) | 가능 |
| `--no-compress` | 압축 안 함 | 가능(스트림이 원본 크기로 커짐) |
| `--sleep-msecs=N` | 1MB당 N ms 대기(부하 조절) | 가능 |
| `-r, --remove-archive` | 불필요 log-archive 삭제 | 가능(원본 영향, 주의) |
| `-o, --output-file` | 상세 메시지 파일 출력 | 가능 |
| `-k, --separate-keys` | TDE 키 파일 분리 | 사용 불가(FIFO 대상 거부) |

사용 가능한 옵션을 모두 넣은 예제(-k 제외). 방식 A (옵션은 CUBRID_BK_OPT 로, -D/-l 은 스크립트가 지정):
```
REMOTE_IP=<BACKUP_IP> REMOTE_PORT=9099 DB=<DB> LEVEL=0 TIMEOUT=60 \
  CUBRID_BK_OPT="-C --no-check -t 4 --no-compress --sleep-msecs 5 -o backup_verbose.txt -r" \
  bash remote_backupdb.sh
```
방식 B (직접):
```
cubrid backupdb -D $FIFO -l 0 -C --no-check -t 4 --no-compress --sleep-msecs 5 \
  -o nhidb_backup_verbose.txt -r <DB>
```
- 검증(2026-07-23): 위 옵션들은 파이프 대상에서 rc=0 로 사용 가능. `-k`(separate-keys)만 사용 불가(CUBRID가 FIFO 대상 거부). 자세한 설명/주의는 `backupdb_옵션_예제.md` 참고.

## 반환코드 (remote_backupdb.sh / rbk_forward)
- 0 : 백업 및 원격 전송 완료
- 2 : 백업 장비 무응답(TIMEOUT 초과) → backupdb 정지 (조건2)
- 3 : 로컬 스풀 최대 크기(SPOOL_MAX, 기본 2G) 초과 → backupdb 정지
- 1 : 기타 오류(backupdb 실패, 완료검증 불일치 등)

## 동작 원리 (방식 A)
```
[DB 서버]                                            [백업 서버]
cubrid backupdb -D FIFO --> (FIFO) --> rbk_forward --TCP--> rbk_listener --> 백업파일
                                        |  로컬 spool 로 먼저 흡수(backupdb 안 막힘 = 커밋 스톨 회피)
                                        |  순단 시 재접속 + offset 이어받기 (조건1)
                                        |  TIMEOUT 초 이상 무응답 -> exit 2 (조건2)
                        remote_backupdb.sh 가 exit 2 감지 -> backupdb 정지 + 오류 로그
```
- 이어받기 프로토콜: 접속 시 수신측이 현재 파일 크기(=받은 바이트)를 알려주고, 송신측은 그 지점부터 spool 을 다시 보냄. 마지막에 'F'(완료검증)로 총 크기 일치를 확인.
- 스풀은 크기 SPOOL_MAX(기본 2G)의 링 버퍼로, 이미 전송(+안전 마진)된 구간을 재사용한다. 총 백업이 SPOOL_MAX 보다 작으면 파일은 그만큼만, 크면 최대 SPOOL_MAX 까지 사용하고 그 이상은 절대 넘지 않는다(완료 후 자동 삭제).
- 원격 전송이 백업 생성 속도를 못 따라가 미전송 백로그가 SPOOL_MAX 를 넘으면 오류를 남기고 백업을 종료한다(rc=3). 이 경우 SPOOL_MAX 를 늘리거나 망/전송 속도를 점검한다.
- 실측(2026-07-23, nhidb 약 168GB→35GB, SPOOL_MAX=2G): 스풀 파일 최대 2,147,483,648B(=2G) 유지, 35GB 전송 rc=0 완료(바이트 일치).

## 백업 장비 유형별 연동
- 일반 리눅스 서버: 방식 A(리스너) 또는 방식 B(ssh)
- S3/오브젝트 스토리지: `s3_cubrid_backup.sh`
- NFS/CIFS NAS: `nfs_cubrid_backup.sh`
- Veritas NetBackup: `netbackup_cubrid_backup.sh` (관리자용 정책 구성은 `NetBackup_CUBRID_정책구성가이드.docx`)

## 실측 (2026-07-23, 운영 nhidb 약 168GB)
- 방식 A: rc=0, 약 4분 33초, 약 35GB(36,721,144,832B)
- 방식 B: rc=0, 약 4분 17초, 약 35GB(36,721,144,832B)
- 두 방식 모두 파일명 `nhidb_bk0v000`, 백업 중 운영 지속.

## 포함 문서
- 원격백업_사용자매뉴얼.docx — 서버 설정/백업 실행 단계별 + 장비 유형별 연동
- NetBackup_CUBRID_정책구성가이드.docx — NetBackup 관리자용 정책 구성
- 실환경_백업검증_체크리스트.docx — S3/NFS/NetBackup 실환경 검증 체크리스트
- 백업방식_A_B_비교.md — 방식 A/B 비교표 + 선택 기준 + 실측
