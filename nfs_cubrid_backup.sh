#!/bin/bash
# nfs_cubrid_backup.sh
#   CUBRID -> NFS/CIFS 공유(NAS) 백업.
#   공유를 마운트한 뒤, 그 경로로 백업한다. 두 가지 모드 지원.
#     MODE=direct : 마운트 경로로 직접 backupdb (간단, 공간 절약. 단 NAS 지연 시 로그단계 커밋 지연 가능)
#     MODE=stage  : 로컬 스테이징 백업 후 마운트로 복사 (운영 안전, 로컬 공간 필요)
set -u
# ===== CUBRID 환경 =====
export CUBRID=${CUBRID:-/home/cubrid/CUBRID}
export CUBRID_DATABASES=$CUBRID/databases
export PATH=$CUBRID/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib
# ===== 설정 =====
DB=${DB:-demodb}
LEVEL=${LEVEL:-0}
CUBRID_BK_OPT=${CUBRID_BK_OPT:---no-check}
MODE=${MODE:-direct}                       # direct | stage
# ----- NAS/마운트 -----
MOUNT_SRC=${MOUNT_SRC:?MOUNT_SRC 필요 (NFS: 192.168.0.50:/vol/backup, CIFS: //192.168.0.50/backup)}
MOUNTPOINT=${MOUNTPOINT:-/mnt/nasbackup}
FS_TYPE=${FS_TYPE:-nfs}                     # nfs | cifs
MOUNT_OPT=${MOUNT_OPT:-}                     # 예 nfs: "rw,hard,timeo=150" / cifs: "username=xx,password=yy"
AUTO_MOUNT=${AUTO_MOUNT:-yes}
DEST_SUBDIR=${DEST_SUBDIR:-cubrid/$DB}
STAGE=${STAGE:-/backup/cubrid_stage/$DB}     # MODE=stage 에서만 사용
RETENTION_DAYS=${RETENTION_DAYS:-0}          # >0 이면 그 일수보다 오래된 백업 폴더 삭제
LOG=${LOG:-/var/log/cubrid_nfs_backup.log}
# ================
log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
TS=$(date +%Y%m%d_%H%M%S)

# 0) 마운트 확인/자동 마운트
if ! mountpoint -q "$MOUNTPOINT"; then
  if [ "$AUTO_MOUNT" = "yes" ]; then
     mkdir -p "$MOUNTPOINT"
     log "[마운트] $FS_TYPE $MOUNT_SRC -> $MOUNTPOINT"
     if [ -n "$MOUNT_OPT" ]; then mount -t "$FS_TYPE" -o "$MOUNT_OPT" "$MOUNT_SRC" "$MOUNTPOINT";
     else mount -t "$FS_TYPE" "$MOUNT_SRC" "$MOUNTPOINT"; fi
     [ $? -ne 0 ] && { log "[실패] 마운트 실패"; exit 3; }
  else
     log "[실패] $MOUNTPOINT 가 마운트되어 있지 않음(AUTO_MOUNT=no)"; exit 3
  fi
fi
DEST="$MOUNTPOINT/$DEST_SUBDIR/$TS"
mkdir -p "$DEST" || { log "[실패] 대상 폴더 생성 불가: $DEST"; exit 1; }

# 1) 백업
if [ "$MODE" = "stage" ]; then
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  log "[1/2] (stage) cubrid backupdb -> $STAGE"
  cubrid backupdb -D "$STAGE" -l "$LEVEL" $CUBRID_BK_OPT "$DB" > "$STAGE/backupdb.out" 2>&1
  BK=$?; [ $BK -ne 0 ] && { log "[실패] backupdb rc=$BK"; tail -5 "$STAGE/backupdb.out"|tee -a "$LOG"; exit 1; }
  log "[2/2] NAS 로 복사 -> $DEST"
  cp -f "$STAGE"/* "$DEST"/ || { log "[실패] NAS 복사 실패(스테이징 보존: $STAGE)"; exit 2; }
  rm -rf "$STAGE"
else
  log "[1/1] (direct) cubrid backupdb -> $DEST"
  cubrid backupdb -D "$DEST" -l "$LEVEL" $CUBRID_BK_OPT "$DB" > "$DEST/backupdb.out" 2>&1
  BK=$?; [ $BK -ne 0 ] && { log "[실패] backupdb rc=$BK"; tail -5 "$DEST/backupdb.out"|tee -a "$LOG"; exit 1; }
fi
log "[백업] 완료 (크기 $(du -sh "$DEST" 2>/dev/null | awk '{print $1}'))"

# 2) 보존정책(선택)
if [ "$RETENTION_DAYS" -gt 0 ] 2>/dev/null; then
  log "[정리] ${RETENTION_DAYS}일 초과 백업 삭제"
  find "$MOUNTPOINT/$DEST_SUBDIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} \; 2>/dev/null
fi
log "[완료] CUBRID($DB) -> NAS 백업 성공: $DEST"
exit 0
