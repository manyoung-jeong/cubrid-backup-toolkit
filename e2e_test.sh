#!/bin/bash
# e2e_test.sh - 실제 CUBRID DB로 원격백업 인터페이스 종단(end-to-end) 시험
#  TC1 정상  : 백업->전송->복원(restoredb)+무결성(checkdb)+행수 일치
#  TC2 조건1 : 전송 중 순단(리스너 kill/재기동) -> 이어받기 완료 -> 복원 검증
#  TC3 조건2 : 백업장비 무응답(리스너 없음, timeout 초과) -> backupdb 정지, rc=2, 오류 로그
#
#  운영 DB는 건드리지 않고 격리 테스트 DB(e2edb) 사용. "원격"은 127.0.0.1 로 대체.
set -u
CUB=/home/claude_user/CUBRID-11.4.5.1899-64e2b82-Linux.x86_64
export CUBRID=$CUB CUBRID_DATABASES=$CUB/databases PATH=$CUB/bin:$PATH LD_LIBRARY_PATH=$CUB/lib:$CUB/cci/lib
WORK=/home/claude_user/test/remote_backup
DB=e2edb
DBDIR=$WORK/e2edb_data
RECV=$WORK/recv
RECVFILE=$RECV/${DB}_bk0v000
PORT=19399
VOL=500M
LOG=$WORK/e2e.log
LLOG=$WORK/e2e_listener.log
cd "$WORK" || exit 1
: > "$LOG"; : > "$LLOG"
log(){ echo "$(date '+%F %T') [e2e] $*" | tee -a "$LOG"; }
PASS=0; FAIL=0
ok(){ log "   >> PASS : $*"; PASS=$((PASS+1)); }
ng(){ log "   >> FAIL : $*"; FAIL=$((FAIL+1)); }

gcc -O2 -o rbk_listener rbk_listener.c || exit 1
gcc -O2 -pthread -o rbk_forward rbk_forward.c || exit 1

stop_listeners(){ pkill -f "rbk_listener $PORT " >/dev/null 2>&1; sleep 0.3; }
cleanup_db(){ cubrid server stop $DB >/dev/null 2>&1; cubrid deletedb $DB >/dev/null 2>&1; rm -rf "$DBDIR"; }
trap 'stop_listeners' EXIT

# ---- 전송 실행 (remote_backupdb.sh) : $1=timeout ; 결과 RC ----
run_transport(){
  REMOTE_IP=127.0.0.1 REMOTE_PORT=$PORT DB=$DB LEVEL=0 TIMEOUT=$1 \
    WORKDIR=$WORK SPOOL=$WORK/spool_$DB LOG=$WORK/remote_backup.log \
    CUBRID_BK_OPT="--SA-mode --no-check" \
    bash remote_backupdb.sh >>"$LOG" 2>&1
  RC=$?
}
# ---- 수신 백업으로 복원+검증 : 반환 0=정상 ----
verify_restore(){
  cubrid server stop $DB >>"$LOG" 2>&1
  cubrid restoredb -B "$RECV" $DB >"$WORK/e2e_restore.out" 2>&1; local rrc=$?
  cubrid checkdb --SA-mode $DB >"$WORK/e2e_checkdb.out" 2>&1; local crc=$?
  cubrid server start $DB >>"$LOG" 2>&1
  local n; n=$(csql -u dba $DB 2>/dev/null -c "SELECT '#CNT#'||CAST(count(*) AS VARCHAR)||'#CNT#' FROM t" | sed -n 's/.*#CNT#\([0-9][0-9]*\)#CNT#.*/\1/p' | tail -1)
  cubrid server stop $DB >>"$LOG" 2>&1
  log "   restoredb rc=$rrc, checkdb rc=$crc, 복원후 행수=${n:-?} (원본=${ORIG:-?})"
  [ "$rrc" -eq 0 ] && [ "$crc" -eq 0 ] && [ "${n:-x}" = "${ORIG:-y}" ]
}

# ===== 0) 격리 테스트 DB 생성 + 데이터 =====
log "0) 테스트 DB 생성: $DB (vol=$VOL)"
cleanup_db
mkdir -p "$DBDIR"
( cd "$DBDIR" && cubrid createdb --db-volume-size=$VOL --log-volume-size=64M $DB en_US.utf8 ) >>"$LOG" 2>&1
cubrid server start $DB >>"$LOG" 2>&1
csql -u dba $DB >>"$LOG" 2>&1 <<'EOF'
CREATE TABLE t(id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(100));
INSERT INTO t(v) SELECT 'row' FROM db_class a, db_class b LIMIT 3000;
COMMIT;
EOF
ORIG=$(csql -u dba $DB 2>/dev/null -c "SELECT '#CNT#'||CAST(count(*) AS VARCHAR)||'#CNT#' FROM t" | sed -n 's/.*#CNT#\([0-9][0-9]*\)#CNT#.*/\1/p' | tail -1)
cubrid server stop $DB >>"$LOG" 2>&1
log "   원본 행수 t = ${ORIG:-?}"

# ===== TC1 정상 =====
log "TC1) 정상: 백업 -> 전송 -> 복원/검증"
stop_listeners; rm -rf "$RECV"; mkdir -p "$RECV"
./rbk_listener $PORT "$RECVFILE" "$LLOG" & L=$!
sleep 0.3
run_transport 60
stop_listeners; wait $L 2>/dev/null
RSZ=$(stat -c %s "$RECVFILE" 2>/dev/null || echo 0)
log "   transport rc=$RC, 수신크기=${RSZ}B"
if [ "$RC" -eq 0 ] && verify_restore; then ok "TC1 정상 백업/전송/복원"; else ng "TC1"; fi

# ===== TC2 조건1: 전송 중 순단 2회 -> 이어받기 =====
log "TC2) 조건1: 전송 중 순단 후 이어받기"
stop_listeners; rm -rf "$RECV"; mkdir -p "$RECV"
./rbk_listener $PORT "$RECVFILE" "$LLOG" & L=$!
sleep 0.3
run_transport 60 &            # 백그라운드로 전송 수행
TP=$!
sleep 1.2; log "   [순단] 리스너 kill"; kill -9 $L 2>/dev/null; sleep 3
log "   [복구] 리스너 재기동(append)"; ./rbk_listener $PORT "$RECVFILE" "$LLOG" & L=$!
wait $TP
stop_listeners; wait $L 2>/dev/null
RSZ=$(stat -c %s "$RECVFILE" 2>/dev/null || echo 0)
log "   transport rc=$RC, 수신크기=${RSZ}B"
if [ "$RC" -eq 0 ] && verify_restore; then ok "TC2 순단 후 이어받기 복원 성공"; else ng "TC2"; fi

# ===== TC3 조건2: 백업장비 무응답 -> backupdb 정지 =====
log "TC3) 조건2: 백업장비 무응답(리스너 없음), timeout=3초"
stop_listeners; rm -rf "$RECV"; mkdir -p "$RECV"    # 리스너 미기동
run_transport 3
log "   transport rc=$RC (기대 2)"
LEFT=$(pgrep -a -f "backupdb .*$DB" | grep -v grep | wc -l)
ERRLOG=$(grep -c "무응답\|응답 없음" "$WORK/remote_backup.log" 2>/dev/null)
log "   남은 backupdb 프로세스=$LEFT, 오류로그 건수=$ERRLOG"
if [ "$RC" -eq 2 ] && [ "$LEFT" -eq 0 ] && [ "$ERRLOG" -ge 1 ]; then ok "TC3 무응답 시 backupdb 정지+로그"; else ng "TC3"; fi

# ===== 정리 =====
log "정리: 테스트 DB/스풀/수신파일 삭제"
cleanup_db
rm -f "$WORK/spool_$DB" "$WORK/bkfifo_$DB"; rm -rf "$RECV"
log "==== 종단 시험 결과: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
