#!/bin/bash
# remote_backupdb.sh
#   cubrid backupdb 결과를 다른 IP의 백업 서버로 전송하는 인터페이스.
#   조건1) 네트워크 순단이 있어도 재접속/이어받기로 백업 정상 완료
#   조건2) 백업 장비가 <TIMEOUT>초 이상 문제면 오류 로그를 남기고 backupdb 정지
#
#   [백업 서버(수신측)] 먼저 실행:
#       ./rbk_listener <PORT> <받을파일경로> <로그>
#   [DB 서버(송신측)] 이 스크립트 실행:
#       REMOTE_IP=1.2.3.4 REMOTE_PORT=9099 DB=demodb bash remote_backupdb.sh
set -u

# ===================== 설정 =====================
DB=${DB:-demodb}
LEVEL=${LEVEL:-0}                                  # 백업 레벨 0/1/2
REMOTE_IP=${REMOTE_IP:-192.168.0.100}              # 백업 서버 IP
REMOTE_PORT=${REMOTE_PORT:-9099}
TIMEOUT=${TIMEOUT:-60}                             # 백업장비 무응답 허용 시간(초) -> 초과 시 backupdb 정지
WORKDIR=${WORKDIR:-/home/claude_user/test/remote_backup}
SPOOL=${SPOOL:-$WORKDIR/spool_${DB}.bkstream}      # 로컬 스풀(백업 크기만큼 여유 공간 필요)
LOG=${LOG:-$WORKDIR/remote_backup.log}
FIFO=$WORKDIR/bkfifo_${DB}
CUBRID_BK_OPT=${CUBRID_BK_OPT:---no-check}         # 필요시 옵션 추가
# ================================================

cd "$WORKDIR" || exit 1
log(){ echo "$(date '+%F %T') [wrap] $*" | tee -a "$LOG"; }

# 0) 포워더 빌드
if [ ! -x ./rbk_forward ] || [ rbk_forward.c -nt ./rbk_forward ]; then
    gcc -O2 -pthread -o rbk_forward rbk_forward.c || { log "rbk_forward 빌드 실패"; exit 1; }
fi

# 1) FIFO/스풀 준비
rm -f "$FIFO" "$SPOOL"; mkfifo "$FIFO" || { log "mkfifo 실패"; exit 1; }
log "원격 백업 시작 DB=$DB level=$LEVEL -> ${REMOTE_IP}:${REMOTE_PORT} (timeout=${TIMEOUT}s)"

# 2) 포워더 기동 (FIFO 를 읽어 원격 전송)
./rbk_forward "$REMOTE_IP" "$REMOTE_PORT" "$SPOOL" "$TIMEOUT" "$LOG" < "$FIFO" &
FWD=$!

# 3) backupdb 기동 (FIFO 로 스트림)
cubrid backupdb -D "$FIFO" -l "$LEVEL" $CUBRID_BK_OPT "$DB" > "$WORKDIR/backupdb_${DB}.out" 2>&1 &
BK=$!

# 4) 감시 : 포워더 종료코드/백업 종료를 폴링
FWD_RC=0; BK_DONE=0
while :; do
    if ! kill -0 "$FWD" 2>/dev/null; then wait "$FWD"; FWD_RC=$?; break; fi
    if ! kill -0 "$BK"  2>/dev/null; then BK_DONE=1; wait "$FWD"; FWD_RC=$?; break; fi
    sleep 1
done

# 5) 조건2 : 포워더가 원격장비 무응답으로 종료(2) -> backupdb 정지
if [ "$FWD_RC" -eq 2 ]; then
    log "[오류] 백업 장비(${REMOTE_IP}:${REMOTE_PORT})가 ${TIMEOUT}초 이상 응답 없음 -> backupdb 정지"
    kill -TERM "$BK" 2>/dev/null; sleep 2; kill -KILL "$BK" 2>/dev/null; wait "$BK" 2>/dev/null
    rm -f "$FIFO"
    exit 2
fi

# 6) 정상 경로 : backupdb 종료 확인
wait "$BK" 2>/dev/null; BK_RC=$?
rm -f "$FIFO"
if [ "$FWD_RC" -eq 0 ] && [ "$BK_RC" -eq 0 ]; then
    log "백업 및 원격 전송 완료 (원격=${REMOTE_IP}:${REMOTE_PORT}, 스풀 삭제)"
    rm -f "$SPOOL"
    exit 0
else
    log "[오류] backupdb rc=$BK_RC, forwarder rc=$FWD_RC (스풀 보존: $SPOOL)"
    kill -KILL "$FWD" 2>/dev/null
    exit 1
fi
