#!/bin/bash
# e2e_devices_test.sh - S3 / NFS / NetBackup 백업 스크립트의 격리 종단 시험
#   실제 S3/NAS/NetBackup 이 없는 환경이므로, PATH 에 mock 스텁(aws, bpbackup, bpclntcmd,
#   mount, mountpoint)을 넣어 "대상"만 시뮬레이션한다. 단, 실제 cubrid backupdb 로 백업하고
#   각 방식이 남긴 백업본을 restoredb + checkdb + 행수 비교로 진짜 무결성 검증한다.
#   -> 스크립트 로직(백업->수집->재시도->정리)과 백업본 복원 가능성을 종단 확인.
set -u
CUB=/home/claude_user/CUBRID-11.4.5.1899-64e2b82-Linux.x86_64
export CUBRID=$CUB CUBRID_DATABASES=$CUB/databases LD_LIBRARY_PATH=$CUB/lib:$CUB/cci/lib
WORK=/home/claude_user/test/remote_backup
DB=e2edb; DBDIR=$WORK/e2edb_data; VOL=500M
LOG=$WORK/e2e_devices.log
cd "$WORK" || exit 1; : > "$LOG"
log(){ echo "$(date '+%F %T') [e2e-dev] $*" | tee -a "$LOG"; }
PASS=0; FAIL=0
ok(){ log "   >> PASS : $*"; PASS=$((PASS+1)); }
ng(){ log "   >> FAIL : $*"; FAIL=$((FAIL+1)); }

# ---- mock 스텁 준비 ----
MB=$WORK/mockbin; rm -rf "$MB"; mkdir -p "$MB"
cat > "$MB/aws" <<'AWS'
#!/bin/bash
ROOT=${MOCK_S3_ROOT:?}; op=""; poss=()
while [ $# -gt 0 ]; do case "$1" in
  --profile|--endpoint-url|--storage-class) shift 2;;
  --recursive|--only-show-errors) shift;;
  s3) shift;; cp|ls) op="$1"; shift;;
  -*) shift;; *) poss+=("$1"); shift;; esac; done
toloc(){ local p="${1#s3://}"; echo "$ROOT/$p"; }
if [ "$op" = "cp" ]; then d=$(toloc "${poss[1]}"); mkdir -p "$d"; cp -r "${poss[0]}"/* "$d"/ 2>/dev/null; exit 0
elif [ "$op" = "ls" ]; then ls -l "$(toloc "${poss[0]}")" 2>/dev/null; exit 0; fi
exit 0
AWS
cat > "$MB/bpbackup" <<'BP'
#!/bin/bash
VAULT=${MOCK_NBU_VAULT:?}; FAILF=${MOCK_NBU_FAIL_FILE:-/nonexist}
if [ -f "$FAILF" ]; then c=$(cat "$FAILF" 2>/dev/null||echo 0); if [ "${c:-0}" -gt 0 ] 2>/dev/null; then echo $((c-1))>"$FAILF"; echo "mock bpbackup: simulated failure"; exit 1; fi; fi
dir=""; while [ $# -gt 0 ]; do case "$1" in -p|-s|-k|-L) shift 2;; -w) shift;; -*) shift;; *) dir="$1"; shift;; esac; done
mkdir -p "$VAULT"; cp -r "$dir"/* "$VAULT"/ 2>/dev/null; exit 0
BP
printf '#!/bin/bash\nexit 0\n' > "$MB/bpclntcmd"
printf '#!/bin/bash\nexit 0\n' > "$MB/mount"
printf '#!/bin/bash\nexit 0\n' > "$MB/mountpoint"   # 항상 "마운트됨"으로 간주
chmod +x "$MB"/*
export PATH="$MB:$CUB/bin:$PATH"

cleanup_db(){ cubrid server stop $DB >/dev/null 2>&1; cubrid deletedb $DB >/dev/null 2>&1; rm -rf "$DBDIR"; }
trap 'cleanup_db; rm -rf "$MB"' EXIT

# 백업본을 찾아 복원+검증
verify_restore(){  # $1=검색루트
  local bf; bf=$(find "$1" -name "${DB}_bk0v000" 2>/dev/null | head -1)
  [ -z "$bf" ] && { log "   백업파일 못 찾음(under $1)"; return 1; }
  local bdir; bdir=$(dirname "$bf")
  cubrid server stop $DB >>"$LOG" 2>&1
  cubrid restoredb -B "$bdir" $DB >"$WORK/dev_rest.out" 2>&1; local rrc=$?
  cubrid checkdb --SA-mode $DB >"$WORK/dev_chk.out" 2>&1; local crc=$?
  cubrid server start $DB >>"$LOG" 2>&1
  local n; n=$(csql -u dba $DB 2>/dev/null -c "SELECT '#CNT#'||CAST(count(*) AS VARCHAR)||'#CNT#' FROM t" | sed -n 's/.*#CNT#\([0-9][0-9]*\)#CNT#.*/\1/p' | tail -1)
  cubrid server stop $DB >>"$LOG" 2>&1
  log "   백업파일=$bf | restoredb=$rrc checkdb=$crc 행수=${n:-?}(원본 $ORIG)"
  [ "$rrc" -eq 0 ] && [ "$crc" -eq 0 ] && [ "${n:-x}" = "$ORIG" ]
}

# ===== 0) 격리 DB 생성 =====
log "0) 테스트 DB 생성 $DB"
cleanup_db; mkdir -p "$DBDIR"
( cd "$DBDIR" && cubrid createdb --db-volume-size=$VOL --log-volume-size=64M $DB en_US.utf8 ) >>"$LOG" 2>&1
cubrid server start $DB >>"$LOG" 2>&1
csql -u dba $DB >>"$LOG" 2>&1 <<'EOF'
CREATE TABLE t(id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(100));
INSERT INTO t(v) SELECT 'row' FROM db_class a, db_class b LIMIT 3000;
COMMIT;
EOF
ORIG=$(csql -u dba $DB 2>/dev/null -c "SELECT '#CNT#'||CAST(count(*) AS VARCHAR)||'#CNT#' FROM t" | sed -n 's/.*#CNT#\([0-9][0-9]*\)#CNT#.*/\1/p' | tail -1)
cubrid server stop $DB >>"$LOG" 2>&1
log "   원본 행수=$ORIG"
BKOPT="--SA-mode --no-check"    # 오프라인 일관 백업(복원 검증 편의)

# ===== TC1) S3 방식 =====
log "TC1) S3 백업 스크립트"
export MOCK_S3_ROOT=$WORK/mock_s3; rm -rf "$MOCK_S3_ROOT"
DB=$DB LEVEL=0 STAGE=$WORK/stage_s3 KEEP_STAGE=no CUBRID_BK_OPT="$BKOPT" \
  S3_URI=s3://vault/cubrid/$DB AWS_BIN=$MB/aws LOG=$WORK/s3.log \
  bash s3_cubrid_backup.sh >>"$LOG" 2>&1
RC=$?; log "   s3 스크립트 rc=$RC"
if [ "$RC" -eq 0 ] && verify_restore "$MOCK_S3_ROOT"; then ok "S3 백업->업로드->복원"; else ng "S3"; fi

# ===== TC2) NFS 방식 =====
log "TC2) NFS/CIFS 백업 스크립트 (mount/mountpoint mock, 로컬 디렉토리를 NAS로 사용)"
NAS=$WORK/mock_nas; rm -rf "$NAS"; mkdir -p "$NAS"
DB=$DB LEVEL=0 CUBRID_BK_OPT="$BKOPT" MODE=direct \
  MOUNT_SRC=dummy:/vol MOUNTPOINT=$NAS FS_TYPE=nfs AUTO_MOUNT=yes DEST_SUBDIR=cubrid/$DB \
  LOG=$WORK/nfs.log \
  bash nfs_cubrid_backup.sh >>"$LOG" 2>&1
RC=$?; log "   nfs 스크립트 rc=$RC"
if [ "$RC" -eq 0 ] && verify_restore "$NAS"; then ok "NFS 백업->NAS->복원"; else ng "NFS"; fi

# ===== TC3) NetBackup 방식 (수집 성공) =====
log "TC3) NetBackup 백업 스크립트 (bpbackup mock, 성공)"
export MOCK_NBU_VAULT=$WORK/mock_nbu; rm -rf "$MOCK_NBU_VAULT"
unset MOCK_NBU_FAIL_FILE
DB=$DB LEVEL=0 STAGE=$WORK/stage_nbu KEEP_STAGE=no CUBRID_BK_OPT="$BKOPT" \
  NBU_BIN=$MB POLICY=CUBRID_FS SCHEDULE=UserBk KEYWORD=e2e RETRY=2 RETRY_WAIT=1 LOG=$WORK/nbu.log \
  bash netbackup_cubrid_backup.sh >>"$LOG" 2>&1
RC=$?; log "   netbackup 스크립트 rc=$RC"
if [ "$RC" -eq 0 ] && verify_restore "$MOCK_NBU_VAULT"; then ok "NetBackup 백업->수집->복원"; else ng "NetBackup"; fi

# ===== TC4) NetBackup 재시도 (1회 실패 후 성공) =====
log "TC4) NetBackup 재시도 검증 (bpbackup 1회 실패 후 성공)"
export MOCK_NBU_VAULT=$WORK/mock_nbu2; rm -rf "$MOCK_NBU_VAULT"
export MOCK_NBU_FAIL_FILE=$WORK/.nbu_fail; echo 1 > "$MOCK_NBU_FAIL_FILE"
DB=$DB LEVEL=0 STAGE=$WORK/stage_nbu2 KEEP_STAGE=no CUBRID_BK_OPT="$BKOPT" \
  NBU_BIN=$MB POLICY=CUBRID_FS SCHEDULE=UserBk KEYWORD=e2e RETRY=3 RETRY_WAIT=1 LOG=$WORK/nbu2.log \
  bash netbackup_cubrid_backup.sh >>"$LOG" 2>&1
RC=$?; RETRIED=$(grep -c "재시도" "$WORK/nbu2.log" 2>/dev/null)
log "   netbackup(재시도) rc=$RC, 재시도로그=$RETRIED"
rm -f "$MOCK_NBU_FAIL_FILE"
if [ "$RC" -eq 0 ] && [ "${RETRIED:-0}" -ge 1 ] && verify_restore "$MOCK_NBU_VAULT"; then ok "NetBackup 재시도 후 성공"; else ng "NetBackup 재시도"; fi

# ===== 정리 =====
log "정리"
cleanup_db
rm -rf "$WORK/mock_s3" "$WORK/mock_nas" "$WORK/mock_nbu" "$WORK/mock_nbu2" \
       "$WORK/stage_s3" "$WORK/stage_nbu" "$WORK/stage_nbu2" "$MB"
log "==== 장비별 종단 시험 결과: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
