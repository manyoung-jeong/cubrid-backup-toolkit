#!/bin/bash
# nhidb(운영중) 온라인 백업을 ssh 스트리밍으로 백업 서버에 직접 전송
#   기본 대상: cubrid@192.168.7.39:/home/cubrid/db_backupdb
set -u
export CUBRID=/home/claude_user/CUBRID-11.4.5.1899-64e2b82-Linux.x86_64
export CUBRID_DATABASES=$CUBRID/databases
export PATH=$CUBRID/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib
KEY=${KEY:-~/.ssh/nhidb_stream_key}
RUSER=${RUSER:-cubrid}                             # 백업 서버 계정
RHOST=${RHOST:-$RUSER@192.168.7.39}
RDIR=${RDIR:-/home/cubrid/db_backupdb}             # 백업 서버 저장 경로
SSHOPT="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
WORK=/home/claude_user/test/remote_backup
TS=$(date +%Y%m%d_%H%M%S)
RSUB=$RDIR/nhidb_${TS}                              # 회차별 디렉터리(충돌 방지)
RFILE=$RSUB/nhidb_bk0v000                           # backupdb 기본 파일명과 동일
FIFO=$WORK/nhidb_fifo_${TS}                         # 유니크 FIFO (-D 대상)
LOG=$WORK/nhidb_stream.log
VERB=$WORK/nhidb_backup_verbose.txt
cd "$WORK"
log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

rm -f "$FIFO"; mkfifo "$FIFO"
log "[시작] nhidb 온라인 백업 -> ${RHOST}:${RFILE} (스트리밍)"

# 1) 원격으로 FIFO 스트림 전송 (소비자)
( cat "$FIFO" | ssh $SSHOPT $RHOST "mkdir -p '$RSUB'; cat > '$RFILE'"; echo $? > "$WORK/.ssh_rc" ) &
CONS=$!

# 2) backupdb 로 FIFO 에 스트림 (온라인, level 0)
cubrid backupdb -D "$FIFO" -o "$VERB" -l 0 --no-check nhidb > "$WORK/nhidb_backupdb.out" 2>&1
BK_RC=$?
wait $CONS
SSH_RC=$(cat "$WORK/.ssh_rc" 2>/dev/null || echo "?")
rm -f "$FIFO" "$WORK/.ssh_rc"

RSIZE=$(ssh $SSHOPT $RHOST "ls -l '$RFILE' 2>/dev/null | awk '{print \$5}'" 2>/dev/null)
log "[종료] backupdb rc=$BK_RC, ssh rc=$SSH_RC, 원격파일=$RFILE 크기=${RSIZE:-?}B"
if [ "$BK_RC" -eq 0 ] && [ "$SSH_RC" = "0" ]; then
    log "[성공] nhidb 원격 백업 완료 : ${RHOST}:${RFILE} (${RSIZE}B)"
    exit 0
else
    log "[실패] backupdb rc=$BK_RC ssh rc=$SSH_RC (원격 파일 불완전 가능) -> 원격 정리 권장"
    exit 1
fi
