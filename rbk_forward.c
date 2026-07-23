/* rbk_forward.c - 백업 스트림(stdin=FIFO) -> 로컬 spool -> 원격 백업서버 전송
 *   조건1) 네트워크 순단 시 재접속/이어받기로 백업을 정상 완료
 *   조건2) 원격 백업장비가 <timeout>초(기본 60) 이상 응답 없으면 로그 남기고 exit(2)
 *          (상위 래퍼가 이 코드를 보고 backupdb 를 정지시킨다)
 * 빌드 : gcc -O2 -pthread -o rbk_forward rbk_forward.c
 * 사용 : ./rbk_forward <remote_ip> <port> <spool_file> <timeout_sec> [log_file]
 * 반환 : 0=전송완료, 2=원격장비 오류(무응답 타임아웃), 1=기타오류
 *
 * 설계: reader 스레드가 stdin(FIFO)을 로컬 spool 파일로 빠르게 흡수하여 backupdb 가
 *       네트워크 때문에 멈추지 않게 한다(커밋 스톨 회피). sender 스레드가 spool 을
 *       원격으로 전송하며 순단 시 offset 핸드셰이크로 이어받는다. watchdog 스레드가
 *       마지막 정상시각을 감시해 timeout 초과 시 종료한다.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdint.h>
#include <poll.h>

#define CHUNK (1 << 20)

static FILE *g_log;
static const char *g_ip; static int g_port, g_timeout;
static int g_spool_rfd, g_spool_wfd;
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
static off_t   g_total = 0;      /* spool 에 기록된 총 바이트 */
static int     g_eof = 0;        /* stdin(FIFO) EOF (backupdb 종료) */
static time_t  g_last_ok;        /* 마지막으로 원격이 정상이던 시각 */

static void logmsg(const char *fmt, ...) {
    char ts[32]; time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tm);
    va_list ap; va_start(ap, fmt);
    fprintf(g_log, "%s [forward] ", ts); vfprintf(g_log, fmt, ap); fprintf(g_log, "\n"); fflush(g_log);
    va_end(ap);
}
static ssize_t writen(int fd, const void *b, size_t n){ size_t l=n; const char*p=b; while(l){ ssize_t w=write(fd,p,l); if(w<0){ if(errno==EINTR)continue; return -1;} if(w==0)return -1; l-=w; p+=w;} return (ssize_t)n; }
static ssize_t readn(int fd, void *b, size_t n){ size_t l=n; char*p=b; while(l){ ssize_t r=read(fd,p,l); if(r<0){ if(errno==EINTR)continue; return -1;} if(r==0)break; l-=r; p+=r;} return (ssize_t)(n-l); }
static void put64(unsigned char*b, uint64_t v){ for(int i=7;i>=0;i--){b[i]=(unsigned char)(v&0xff); v>>=8;} }
static uint64_t get64(const unsigned char*b){ uint64_t v=0; for(int i=0;i<8;i++) v=(v<<8)|b[i]; return v; }
static void set_last_ok(void){ pthread_mutex_lock(&g_mx); g_last_ok=time(NULL); pthread_mutex_unlock(&g_mx); }

/* 논블로킹 connect + poll 타임아웃(5s), 성공 시 송수신 타임아웃 10s 설정 */
static int connect_to(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0); if (s < 0) return -1;
    int fl = fcntl(s, F_GETFL, 0); fcntl(s, F_SETFL, fl | O_NONBLOCK);
    struct sockaddr_in a; memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = htons(g_port);
    if (inet_pton(AF_INET, g_ip, &a.sin_addr) != 1) { close(s); return -1; }
    int rc = connect(s, (struct sockaddr *)&a, sizeof a);
    if (rc < 0 && errno == EINPROGRESS) {
        struct pollfd pf = { s, POLLOUT, 0 };
        if (poll(&pf, 1, 5000) <= 0) { close(s); return -1; }
        int err = 0; socklen_t el = sizeof err; getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &el);
        if (err) { close(s); return -1; }
    } else if (rc < 0) { close(s); return -1; }
    fcntl(s, F_SETFL, fl);                       /* 다시 블로킹 */
    struct timeval tv = { 10, 0 };
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    return s;
}

static void *reader_thread(void *arg) {
    (void)arg; char *buf = malloc(CHUNK); ssize_t r;
    while ((r = read(0, buf, CHUNK)) > 0) {
        if (writen(g_spool_wfd, buf, r) != r) { logmsg("spool 쓰기 오류 %s", strerror(errno)); break; }
        pthread_mutex_lock(&g_mx); g_total += r; pthread_mutex_unlock(&g_mx);
    }
    pthread_mutex_lock(&g_mx); g_eof = 1; pthread_mutex_unlock(&g_mx);
    free(buf);
    return NULL;
}

static void *watchdog_thread(void *arg) {
    (void)arg;
    for (;;) {
        sleep(1);
        pthread_mutex_lock(&g_mx); time_t last = g_last_ok; int eof = g_eof; off_t total = g_total; pthread_mutex_unlock(&g_mx);
        (void)eof; (void)total;
        if (time(NULL) - last > g_timeout) {
            logmsg("[오류] 원격 백업장비 %s:%d 가 %d초 이상 무응답 -> 전송 중단(exit 2)", g_ip, g_port, g_timeout);
            fflush(g_log);
            _exit(2);
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: %s <remote_ip> <port> <spool_file> <timeout_sec> [log_file]\n", argv[0]); return 1; }
    g_ip = argv[1]; g_port = atoi(argv[2]); const char *spool = argv[3]; g_timeout = atoi(argv[4]);
    g_log = (argc >= 6) ? fopen(argv[5], "a") : stderr; if (!g_log) g_log = stderr;
    signal(SIGPIPE, SIG_IGN);

    g_spool_wfd = open(spool, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    g_spool_rfd = open(spool, O_RDONLY);
    if (g_spool_wfd < 0 || g_spool_rfd < 0) { logmsg("spool 열기 실패 %s : %s", spool, strerror(errno)); return 1; }
    g_last_ok = time(NULL);
    logmsg("시작 -> %s:%d timeout=%ds spool=%s", g_ip, g_port, g_timeout, spool);

    pthread_t tr, tw;
    pthread_create(&tr, NULL, reader_thread, NULL);
    pthread_create(&tw, NULL, watchdog_thread, NULL);

    char *buf = malloc(CHUNK);
    for (;;) {
        int s = connect_to();
        if (s < 0) { sleep(1); continue; }           /* 실패시 last_ok 갱신 안함 -> watchdog 누적 */
        set_last_ok();
        unsigned char cmd = 'D', b8[8];
        if (writen(s, &cmd, 1) != 1 || readn(s, b8, 8) != 8) { close(s); continue; }
        off_t sent = (off_t)get64(b8);               /* 원격이 이미 받은 크기 = 이어받기 지점 */

        int broke = 0;
        for (;;) {
            pthread_mutex_lock(&g_mx); off_t total = g_total; int eof = g_eof; pthread_mutex_unlock(&g_mx);
            if (sent < total) {
                size_t want = (size_t)((total - sent) < CHUNK ? (total - sent) : CHUNK);
                ssize_t rd = pread(g_spool_rfd, buf, want, sent);
                if (rd <= 0) { broke = 1; break; }
                if (writen(s, buf, rd) != rd) { broke = 1; break; }   /* 전송 실패 -> 재접속 */
                sent += rd; set_last_ok();
            } else if (eof) {
                break;                                 /* 모두 전송 + backupdb 종료 */
            } else {
                set_last_ok(); usleep(50 * 1000);      /* 따라잡음(연결 정상), backupdb 산출 대기 */
            }
        }
        close(s);
        if (broke) continue;                           /* 재접속하여 이어받기 */

        /* 완료 검증(F) */
        int v = connect_to();
        if (v < 0) { sleep(1); continue; }
        set_last_ok();
        cmd = 'F';
        pthread_mutex_lock(&g_mx); off_t total = g_total; pthread_mutex_unlock(&g_mx);
        unsigned char t8[8]; put64(t8, (uint64_t)total);
        unsigned char status = 1;
        if (writen(v, &cmd, 1) == 1 && readn(v, b8, 8) == 8 && writen(v, t8, 8) == 8 && readn(v, &status, 1) == 1) {
            close(v);
            if (status == 0) { logmsg("전송 완료 total=%lld", (long long)total); free(buf); return 0; }
            logmsg("[오류] 완료 검증 불일치(total=%lld)", (long long)total); free(buf); return 1;
        }
        close(v);                                      /* 검증 연결 실패 -> 재시도 */
    }
}
