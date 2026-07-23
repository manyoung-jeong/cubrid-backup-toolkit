#!/bin/bash
# run_nhidb_A.sh - 방식 A(재개형)로 nhidb를 cubrid@192.168.7.39:/home/cubrid/db_backupdb 로 파이프 백업
#   리스너 기동 -> 포트 확인 -> 백업 -> 결과확인 을 한 번에 수행(단계 누락 방지).
#   실행:  bash run_nhidb_A.sh
set -u
export CUBRID=${CUBRID:-/home/claude_user/CUBRID-11.4.5.1899-64e2b82-Linux.x86_64}
export CUBRID_DATABASES=$CUBRID/databases
export PATH=$CUBRID/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib
cd /home/claude_user/test/remote_backup || exit 1
KEY=${KEY:-~/.ssh/nhidb_stream_key}
RUSER=${RUSER:-cubrid}                             # 백업 서버 계정
RIP=${RIP:-192.168.7.39}
RDIR=${RDIR:-/home/cubrid/db_backupdb}             # 백업 서버 저장/리스너 경로
SSHOPT="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15"
R=$RUSER@$RIP
DB=${DB:-nhidb}; PORT=${PORT:-9099}; LEVEL=${LEVEL:-0}; TIMEOUT=${TIMEOUT:-120}
TS=$(date +%Y%m%d_%H%M%S)
RSUB=$RDIR/${DB}_${TS}                              # 회차별 디렉터리(충돌 방지)
RFILE=$RSUB/${DB}_bk${LEVEL}v000                    # backupdb 기본 파일명과 동일

echo "[1/4] 원격 리스너 기동 -> $R:$RFILE"
ssh $SSHOPT $R "mkdir -p $RSUB; nohup $RDIR/rbk_listener $PORT $RFILE $RSUB/rbk.log >/dev/null 2>&1 & sleep 1; echo started" 2>&1 | grep -v Warning
sleep 1

echo "[2/4] 포트 $PORT 도달 확인"
if timeout 6 bash -c "cat </dev/null >/dev/tcp/$RIP/$PORT" 2>/dev/null; then
  echo "  OPEN (리스너 정상)"
else
  echo "  CLOSED - 리스너가 안 떴습니다. 원격에서 재빌드 후 재시도:"
  echo "    ssh $R 'cd $RDIR && gcc -O2 -std=gnu99 -o rbk_listener rbk_listener.c'"
  exit 1
fi

echo "[3/4] 방식 A 백업 실행 (약 6~7분)"
REMOTE_IP=$RIP REMOTE_PORT=$PORT DB=$DB LEVEL=$LEVEL TIMEOUT=$TIMEOUT CUBRID_BK_OPT="--no-check" \
  bash remote_backupdb.sh
RC=$?

echo "[4/4] 결과 (rc=$RC)"
ssh $SSHOPT $R "ls -lh $RFILE 2>/dev/null || echo '원격 파일 없음'" 2>&1 | grep -v Warning
[ "$RC" -eq 0 ] && echo "==> 성공: $R:$RFILE" || echo "==> 실패(rc=$RC): 위 로그 확인"
exit $RC
