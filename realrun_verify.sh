#!/bin/bash
# realrun_verify.sh - 실환경(mock 없이) 백업 방식 자동 검증
#   흐름: (선택)백업 실행 -> 대상에서 백업본 가져오기 -> 격리 위치로 복원(restoredb -u -p) -> checkdb -> PASS/FAIL
#   안전: 복원은 항상 별도 CUBRID_DATABASES + 격리 경로로 수행하여 운영 DB 파일을 절대 덮어쓰지 않는다.
#
#   사용:
#     METHOD=dir  BK_DIR=<백업본디렉토리> DB=<db> bash realrun_verify.sh
#     METHOD=s3   DB=<db> S3_URI=s3://<bucket>/cubrid/<db> [AWS_PROFILE=..][AWS_ENDPOINT=..] bash realrun_verify.sh
#     METHOD=nfs  DB=<db> MOUNT_SRC=<nas>:/vol MOUNTPOINT=/mnt/nasbackup DEST_SUBDIR=cubrid/<db> [FS_TYPE=nfs] bash realrun_verify.sh
#     METHOD=nbu  DB=<db> POLICY=<정책> SCHEDULE=<스케줄> CLIENT=<client> [NBU_BIN=/usr/openv/netbackup/bin] bash realrun_verify.sh
set -u
: "${CUBRID:?CUBRID 환경변수 필요}"
export CUBRID_DATABASES=${CUBRID_DATABASES:-$CUBRID/databases}
export PATH=$CUBRID/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib
METHOD=${METHOD:?METHOD 필요 (dir|s3|nfs|nbu)}
DB=${DB:?DB 필요}
LEVEL=${LEVEL:-0}
WORK=${WORK:-$(pwd)}
FETCH=$WORK/verify_fetch_$DB
LOG=${LOG:-$WORK/realrun_verify.log}
CUBRID_BK_OPT=${CUBRID_BK_OPT:---no-check}     # 운영(온라인) 기본. 스크래치면 --SA-mode 가능
SCRIPTDIR=${SCRIPTDIR:-$WORK}
log(){ echo "$(date '+%F %T') [verify] $*" | tee -a "$LOG"; }

# 안전 가드: 이 호스트에서 동일 이름 DB 서버가 구동 중이면 SA 검증이 shm 이름 충돌 가능
if cubrid server status 2>/dev/null | grep -qE "Server $DB \("; then
  if [ "${RUN_ANYWAY:-no}" != "yes" ]; then
    log "[중단] 이 호스트에서 '$DB' 서버가 구동 중입니다. 동일 이름 SA 검증은 충돌 위험이 있어 중단합니다."
    log "  -> 검증 전용 호스트에서 실행하거나, RUN_ANYWAY=yes 로 강제(권장하지 않음)."
    exit 3
  fi
  log "[경고] '$DB' 서버 구동 중이나 RUN_ANYWAY=yes 로 계속."
fi

rm -rf "$FETCH"; mkdir -p "$FETCH"

# ---- 1) 백업 실행 + 대상에서 백업본 가져오기 (METHOD 별) ----
case "$METHOD" in
  dir)
    : "${BK_DIR:?BK_DIR 필요}"; log "[1] 기존 백업본 사용: $BK_DIR"; FETCH="$BK_DIR" ;;
  s3)
    : "${S3_URI:?S3_URI 필요}"; AWS=${AWS_BIN:-aws}
    PROF=${AWS_PROFILE:+--profile $AWS_PROFILE}; EP=${AWS_ENDPOINT:+--endpoint-url $AWS_ENDPOINT}
    log "[1] S3 백업 실행"
    DB=$DB LEVEL=$LEVEL STAGE=$WORK/stage_$DB KEEP_STAGE=no CUBRID_BK_OPT="$CUBRID_BK_OPT" \
      S3_URI="$S3_URI" AWS_PROFILE="${AWS_PROFILE:-}" AWS_ENDPOINT="${AWS_ENDPOINT:-}" LOG="$WORK/s3.log" \
      bash "$SCRIPTDIR/s3_cubrid_backup.sh" >>"$LOG" 2>&1 || { log "[실패] s3 백업 스크립트"; exit 1; }
    TS=$($AWS $PROF $EP s3 ls "$S3_URI/" | awk '{print $NF}' | grep -E '/$' | sort | tail -1)
    log "[1] 최신 업로드: $S3_URI/$TS -> 다운로드"
    $AWS $PROF $EP s3 cp "$S3_URI/$TS" "$FETCH/" --recursive --only-show-errors || { log "[실패] s3 다운로드"; exit 1; } ;;
  nfs)
    : "${MOUNT_SRC:?}"; : "${MOUNTPOINT:?}"; DEST_SUBDIR=${DEST_SUBDIR:-cubrid/$DB}
    log "[1] NFS 백업 실행"
    DB=$DB LEVEL=$LEVEL CUBRID_BK_OPT="$CUBRID_BK_OPT" MODE=${MODE:-direct} \
      MOUNT_SRC="$MOUNT_SRC" MOUNTPOINT="$MOUNTPOINT" FS_TYPE=${FS_TYPE:-nfs} \
      AUTO_MOUNT=${AUTO_MOUNT:-yes} DEST_SUBDIR="$DEST_SUBDIR" LOG="$WORK/nfs.log" \
      bash "$SCRIPTDIR/nfs_cubrid_backup.sh" >>"$LOG" 2>&1 || { log "[실패] nfs 백업 스크립트"; exit 1; }
    LATEST=$(ls -1dt "$MOUNTPOINT/$DEST_SUBDIR"/*/ 2>/dev/null | head -1)
    log "[1] NAS 최신 백업: $LATEST"; FETCH="$LATEST" ;;
  nbu)
    : "${POLICY:?}"; : "${SCHEDULE:?}"; : "${CLIENT:?CLIENT 필요(bprestore 대상)}"
    NBU_BIN=${NBU_BIN:-/usr/openv/netbackup/bin}; STAGE=$WORK/stage_$DB
    log "[1] NetBackup 백업 실행(스테이징 보존)"
    DB=$DB LEVEL=$LEVEL STAGE="$STAGE" KEEP_STAGE=yes CUBRID_BK_OPT="$CUBRID_BK_OPT" \
      NBU_BIN="$NBU_BIN" POLICY="$POLICY" SCHEDULE="$SCHEDULE" KEYWORD="verify_$DB" LOG="$WORK/nbu.log" \
      bash "$SCRIPTDIR/netbackup_cubrid_backup.sh" >>"$LOG" 2>&1 || { log "[실패] nbu 백업 스크립트"; exit 1; }
    log "[1] bprestore 로 NetBackup 에서 복구: $STAGE"
    "$NBU_BIN/bprestore" -C "$CLIENT" -D "$CLIENT" -t 0 -w -L "$WORK/bprestore.log" "$STAGE" || { log "[실패] bprestore"; exit 1; }
    FETCH="$STAGE" ;;   # bprestore 는 원경로로 복원되므로 STAGE 에서 검증
  *) log "[실패] 알 수 없는 METHOD=$METHOD"; exit 2 ;;
esac

# ---- 2) 격리 복원 + checkdb ----
BF=$(find "$FETCH" -name "${DB}_bk0v000" 2>/dev/null | head -1)
[ -z "$BF" ] && { log "[실패] 백업파일(${DB}_bk0v000) 못 찾음 under $FETCH"; exit 1; }
BDIR=$(dirname "$BF")
ISO=$WORK/verify_iso_$DB; rm -rf "$ISO"; mkdir -p "$ISO/vol"
printf '%s\t%s\tlocalhost\t%s\tfile:%s/lob\n' "$DB" "$ISO/vol" "$ISO/vol" "$ISO/vol" > "$ISO/databases.txt"
log "[2] 격리 복원(restoredb -u -p) -> $ISO/vol"
CUBRID_DATABASES="$ISO" cubrid restoredb -u -p -B "$BDIR" "$DB" > "$WORK/verify_restore.out" 2>&1; RRC=$?
CUBRID_DATABASES="$ISO" cubrid checkdb --SA-mode "$DB" > "$WORK/verify_checkdb.out" 2>&1; CRC=$?
log "[2] restoredb rc=$RRC, checkdb rc=$CRC (백업파일 $BF)"
[ "$RRC" -ne 0 ] && tail -3 "$WORK/verify_restore.out" | sed 's/^/    restore: /' | tee -a "$LOG"
[ "$CRC" -ne 0 ] && tail -3 "$WORK/verify_checkdb.out" | sed 's/^/    checkdb: /' | tee -a "$LOG"
rm -rf "$ISO"; [ "$METHOD" != "dir" ] && [ -d "$FETCH" ] && [[ "$FETCH" == "$WORK/verify_fetch_$DB" ]] && rm -rf "$FETCH"

# ---- 3) 판정 ----
if [ "$RRC" -eq 0 ] && [ "$CRC" -eq 0 ]; then
  log "==== PASS : $METHOD 방식 백업본이 정상 복원/무결(checkdb) ===="; exit 0
else
  log "==== FAIL : $METHOD 방식 검증 실패(restoredb=$RRC checkdb=$CRC) ===="; exit 1
fi
