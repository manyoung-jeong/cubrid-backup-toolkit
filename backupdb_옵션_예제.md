# cubrid backupdb 옵션과 파이프 백업 예제

파이프 백업(방식 A/B)은 `cubrid backupdb` 를 그대로 실행하므로 backupdb 옵션을 대부분 사용할 수 있다.
- 방식 A(remote_backupdb.sh): `-D`(FIFO)와 `-l`(LEVEL)은 스크립트가 지정하고, 나머지 옵션은 `CUBRID_BK_OPT` 로 전달한다.
- 방식 B(직접): `cubrid backupdb` 명령에 옵션을 직접 붙인다.

## 옵션 목록 (cubrid 11.4.5 기준)

| 옵션 | 의미 | 파이프 백업 사용 |
|------|------|------|
| `-D, --destination-path=PATH` | 백업 대상 경로 | 도구가 FIFO로 자동 지정(사용자가 따로 줄 필요 없음) |
| `-l, --level=LEVEL` (0/1/2) | 백업 레벨(0=full, 1/2=증분) | 가능 (방식 A는 `LEVEL` 환경변수) |
| `-C, --CS-mode` | 클라이언트-서버(온라인, 운영 중) 백업 | 가능 (운영 DB 백업의 기본/권장) |
| `-S, --SA-mode` | 스탠드얼론(오프라인) 백업 | 가능하나 DB 서버 정지 필요(운영 중에는 불가) |
| `--no-check` | 백업 전 무결성 검사 생략 | 가능 (도구 기본값) |
| `-t, --thread-count=COUNT` | 백업 스레드 수(0=auto) | 가능 |
| `--no-compress` | 압축 안 함(기본은 LZ4 압축) | 가능하나 스트림이 원본 크기(예: 168GB)로 커져 스풀/네트워크 부담 증가 |
| `--sleep-msecs=N` | 1MB 읽을 때마다 N ms 대기(운영 부하 조절) | 가능 |
| `-r, --remove-archive` | 불필요한 log-archive 삭제 | 가능(원본 DB에 영향, 주의) |
| `-o, --output-file=FILE` | 상세 백업 메시지를 파일로 출력 | 가능(로컬 파일에 기록) |
| `-k, --separate-keys` | TDE 키 파일(_keys)을 백업 볼륨과 분리 | TDE 사용 시에만, 분리 키 파일 경로는 별도 확인 필요 |

## 모든(대부분) 옵션을 넣은 예제

### 방식 A (remote_backupdb.sh, CUBRID_BK_OPT 로 전달)
```
REMOTE_IP=<BACKUP_IP> REMOTE_PORT=9099 DB=<DB> LEVEL=0 TIMEOUT=60 \
  CUBRID_BK_OPT="-C --no-check -t 4 --sleep-msecs 5 -o backup_verbose.txt -r" \
  bash remote_backupdb.sh
```
- `-D`(FIFO)와 `-l 0`(LEVEL=0)은 스크립트가 자동 지정하므로 `CUBRID_BK_OPT` 에 다시 넣지 않는다.
- 압축을 끄려면 `--no-compress` 를 추가(단, 스풀/전송량이 원본 크기로 커짐).
- TDE면 `-k` 추가.

### 방식 B (직접 실행)
```
FIFO=/tmp/bkfifo_$(date +%s); mkfifo $FIFO
cat $FIFO | ssh -i ~/.ssh/bk_key <계정>@<BACKUP_IP> "cat > /path/<DB>_bk0v000" &
cubrid backupdb -D $FIFO -l 0 -C --no-check -t 4 --sleep-msecs 5 \
  -o nhidb_backup_verbose.txt -r <DB>
rm -f $FIFO
```

### 오프라인(정지 DB) 전체 옵션 예 (참고)
```
# DB 서버 정지 후 SA 모드. 압축 해제 + 스레드 8 + archive 삭제 + 키 분리(TDE)
cubrid backupdb -D $FIFO -l 0 -S --no-check -t 8 --no-compress \
  --sleep-msecs 10 -o verbose.txt -r -k <DB>
```

## 주의
- 운영 중(온라인) 백업은 `-S` 대신 `-C`(기본)를 쓴다. `-S`는 서버가 정지된 상태에서만 동작한다.
- `--no-compress` 는 네트워크 전송량과 방식 A 로컬 스풀 사용량을 크게 늘린다(압축 기본 권장).
- `-r`(remove-archive)은 원본 DB의 로그 아카이브를 삭제하므로 복구 정책을 고려해 신중히 사용한다.
- `-k`(separate-keys)는 TDE 사용 환경에서만 의미가 있으며, 분리되는 `_keys` 파일의 저장 위치를 사전에 확인한다.
