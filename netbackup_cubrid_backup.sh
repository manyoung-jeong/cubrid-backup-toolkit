#!/bin/bash
# netbackup_cubrid_backup.sh
#   CUBRID -> Veritas NetBackup 연동 백업.
#   방식: cubrid backupdb 로 스테이징 폴더에 백업한 뒤, bpbackup 으로 NetBackup 에 수집시킨다.
#   (NetBackup 은 CUBRID 전용 에이전트가 없으므로 "백업파일 생성 -> 파일 수집"이 표준 연동)
#
#   전제:
#     - 이 호스트가 NetBackup 클라이언트로 설치/등록되어 있어야 함
#     - NetBackup 마스터에 정책(POLICY)/스케줄(SCHEDULE)이 미리 구성되어 있어야 함
#     - bpbackup 경로는 보통 /usr/openv/netbackup/bin
#   주의: bpbackup 플래그/스케줄 유형은 NetBackup 버전·정책 유형에 따라 다를 수 있으니
#         NetBackup 관리자와 정책명/스케줄명을 확인할 것.
set -u
# ===== CUBRID 환경 =====
export CUBRID=${CUBRID:-/home/cubrid/CUBRID}
export CUBRID_DATABASES=$CUBRID/databases
export PATH=$CUBRID/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib
# ===== 설정 =====
DB=${DB:-demodb}
LEVEL=${LEVEL:-0}                                  # 0 전체 / 1 / 2
STAGE=${STAGE:-/backup/cubrid_stage/$DB}           # 로컬 스테이징(백업 크기만큼 공간 필요)
KEEP_STAGE=${KEEP_STAGE:-no}                        # NBU 수집 후 스테이징 보존(yes/no)
CUBRID_BK_OPT=${CUBRID_BK_OPT:---no-check}
# ----- NetBackup -----
NBU_BIN=${NBU_BIN:-/usr/openv/netbackup/bin}
POLICY=${POLICY:-CUBRID_FS}                         # NetBackup 정책명(관리자 확인)
SCHEDULE=${SCHEDULE:-Default-Application-Backup}    # User/Application 백업 스케줄명(관리자 확인)
KEYWORD=${KEYWORD:-cubrid_${DB}_$(date +%Y%m%d)}
RETRY=${RETRY:-3}                                   # bpbackup 실패 시 재시도 횟수
RETRY_WAIT=${RETRY_WAIT:-60}                         # 재시도 간격(초)
LOG=${LOG:-/var/log/cubrid_nbu_backup.log}
# ================
log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

# 0) NetBackup 연결 사전 점검(선택)
if [ -x "$NBU_BIN/bpclntcmd" ]; then
  "$NBU_BIN/bpclntcmd" -pn >/dev/null 2>&1 && log "[점검] NetBackup 마스터 연결 OK" \
    || log "[경고] NetBackup 연결 확인 실패(그대로 진행)"
fi
if [ ! -x "$NBU_BIN/bpbackup" ]; then log "[실패] bpbackup 을 찾을 수 없음: $NBU_BIN/bpbackup"; exit 3; fi

# 1) CUBRID 스테이징 백업(온라인)
rm -rf "$STAGE"; mkdir -p "$STAGE" || { log "[실패] 스테이징 생성 불가: $STAGE"; exit 1; }
log "[1/3] cubrid backupdb -> $STAGE  (DB=$DB, level=$LEVEL)"
cubrid backupdb -D "$STAGE" -l "$LEVEL" $CUBRID_BK_OPT "$DB" > "$STAGE/backupdb.out" 2>&1
BK=$?
if [ $BK -ne 0 ]; then log "[실패] cubrid backupdb rc=$BK"; tail -5 "$STAGE/backupdb.out" | tee -a "$LOG"; exit 1; fi
log "[1/3] 백업 완료 (크기 $(du -sh "$STAGE" 2>/dev/null | awk '{print $1}'))"

# 2) NetBackup 수집(bpbackup) - 네트워크/장비 순단 대비 재시도
log "[2/3] NetBackup 수집 시작: policy=$POLICY schedule=$SCHEDULE keyword=$KEYWORD"
n=0; RC=1
while [ $n -lt "$RETRY" ]; do
  n=$((n+1))
  "$NBU_BIN/bpbackup" -p "$POLICY" -s "$SCHEDULE" -k "$KEYWORD" -w -L "$STAGE/bpbackup_${n}.log" "$STAGE"
  RC=$?
  if [ $RC -eq 0 ]; then log "[2/3] NetBackup 수집 성공(시도 $n)"; break; fi
  log "[재시도 $n/$RETRY] bpbackup rc=$RC -> ${RETRY_WAIT}초 후 재시도"; sleep "$RETRY_WAIT"
done
if [ $RC -ne 0 ]; then log "[실패] NetBackup 수집 실패 rc=$RC (스테이징 보존: $STAGE)"; exit 2; fi

# 3) 정리
if [ "$KEEP_STAGE" = "no" ]; then rm -rf "$STAGE"; log "[3/3] 스테이징 삭제"; else log "[3/3] 스테이징 보존: $STAGE"; fi
log "[완료] CUBRID($DB) -> NetBackup 백업 성공"
exit 0

# -----------------------------------------------------------------------------
# (대안) 정책 기반 연동:
#   NetBackup 정책의 백업 대상(Backup Selections)에 위 STAGE 폴더를 지정하고,
#   정책의 사전 스크립트(bpstart_notify.<policy>)에서 'cubrid backupdb -D STAGE ...' 를
#   실행하도록 구성하면, NetBackup 스케줄이 돌 때 백업 생성+수집이 함께 수행된다.
# -----------------------------------------------------------------------------
