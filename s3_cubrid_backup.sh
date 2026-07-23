#!/bin/bash
# s3_cubrid_backup.sh
#   CUBRID -> S3(또는 S3 호환 오브젝트 스토리지: MinIO/Ceph 등) 백업.
#   방식: cubrid backupdb 로 로컬 스테이징 후, aws s3 cp 로 업로드(재시도 포함).
#   전제: aws CLI 설치 및 자격증명 구성(aws configure 또는 IAM 역할).
set -u
# ===== CUBRID 환경 =====
export CUBRID=${CUBRID:-/home/cubrid/CUBRID}
export CUBRID_DATABASES=$CUBRID/databases
export PATH=$CUBRID/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib
# ===== 설정 =====
DB=${DB:-demodb}
LEVEL=${LEVEL:-0}
STAGE=${STAGE:-/backup/cubrid_stage/$DB}            # 로컬 스테이징(백업 크기만큼 공간 필요)
KEEP_STAGE=${KEEP_STAGE:-no}
CUBRID_BK_OPT=${CUBRID_BK_OPT:---no-check}
# ----- S3 -----
S3_URI=${S3_URI:?S3_URI 필요 (예: s3://mybucket/cubrid/demodb)}   # 필수
AWS_BIN=${AWS_BIN:-aws}
AWS_PROFILE_OPT=${AWS_PROFILE:+--profile $AWS_PROFILE}
AWS_ENDPOINT_OPT=${AWS_ENDPOINT:+--endpoint-url $AWS_ENDPOINT}     # S3 호환(MinIO 등)일 때
STORAGE_CLASS=${STORAGE_CLASS:-STANDARD}                            # STANDARD_IA / GLACIER 등
RETRY=${RETRY:-3}
RETRY_WAIT=${RETRY_WAIT:-60}
LOG=${LOG:-/var/log/cubrid_s3_backup.log}
# ================
log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
TS=$(date +%Y%m%d_%H%M%S)
DEST="$S3_URI/$TS/"

command -v "$AWS_BIN" >/dev/null 2>&1 || { log "[실패] aws CLI 없음"; exit 3; }

# 1) 로컬 스테이징 백업(온라인) - S3 지연이 운영 DB 커밋에 영향 주지 않도록 로컬에 먼저 받음
rm -rf "$STAGE"; mkdir -p "$STAGE" || { log "[실패] 스테이징 생성 불가"; exit 1; }
log "[1/3] cubrid backupdb -> $STAGE (DB=$DB level=$LEVEL)"
cubrid backupdb -D "$STAGE" -l "$LEVEL" $CUBRID_BK_OPT "$DB" > "$STAGE/backupdb.out" 2>&1
BK=$?
[ $BK -ne 0 ] && { log "[실패] cubrid backupdb rc=$BK"; tail -5 "$STAGE/backupdb.out" | tee -a "$LOG"; exit 1; }
log "[1/3] 백업 완료 (크기 $(du -sh "$STAGE" 2>/dev/null | awk '{print $1}'))"

# 2) S3 업로드(재시도). aws s3 cp 는 대용량을 자동 멀티파트로 올리며, 실패 시 재실행으로 재업로드.
log "[2/3] S3 업로드 -> $DEST"
n=0; RC=1
while [ $n -lt "$RETRY" ]; do
  n=$((n+1))
  "$AWS_BIN" $AWS_PROFILE_OPT $AWS_ENDPOINT_OPT s3 cp "$STAGE" "$DEST" \
      --recursive --only-show-errors --storage-class "$STORAGE_CLASS"
  RC=$?
  if [ $RC -eq 0 ]; then log "[2/3] 업로드 성공(시도 $n)"; break; fi
  log "[재시도 $n/$RETRY] aws s3 cp rc=$RC -> ${RETRY_WAIT}초 후 재시도"; sleep "$RETRY_WAIT"
done
[ $RC -ne 0 ] && { log "[실패] S3 업로드 실패 rc=$RC (스테이징 보존: $STAGE)"; exit 2; }

# 3) 검증 + 정리
log "[검증] 원격 목록:"; "$AWS_BIN" $AWS_PROFILE_OPT $AWS_ENDPOINT_OPT s3 ls "$DEST" | tee -a "$LOG"
if [ "$KEEP_STAGE" = "no" ]; then rm -rf "$STAGE"; log "[3/3] 스테이징 삭제"; else log "[3/3] 스테이징 보존: $STAGE"; fi
log "[완료] CUBRID($DB) -> S3 백업 성공: $DEST"
exit 0

# ---------------------------------------------------------------------------
# (대안) 로컬 공간 없이 스트리밍 업로드(재개 불가, 대용량은 --expected-size 필요):
#   FIFO=/tmp/bkfifo; mkfifo $FIFO
#   cat $FIFO | aws s3 cp - "$S3_URI/$TS/${DB}.bk" --expected-size <바이트> &
#   cubrid backupdb -D $FIFO -l 0 --no-check $DB ; rm -f $FIFO
# ---------------------------------------------------------------------------
