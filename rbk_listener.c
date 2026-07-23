/* rbk_listener.c - 원격 백업 서버(수신측) : 재접속/이어받기(resume) 지원 수신기
 * 빌드 : gcc -O2 -o rbk_listener rbk_listener.c
 * 사용 : ./rbk_listener <port> <output_backup_file> [log_file]
 *
 * 접속 1회 프로토콜:
 *   C->S : 명령 1바이트  'D'(데이터/이어받기) | 'F'(완료검증)
 *   S->C : 현재 파일 크기 8바이트(big-endian) = 이어받기 오프셋
 *   'D'  : C가 오프셋부터 데이터 전송 -> S는 파일에 append (소켓 EOF까지)
 *   'F'  : C가 기대 총크기 8바이트 전송 -> S가 파일크기와 비교, 1바이트(0=일치)회신 후 종료
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
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdint.h>

static FILE *g_log;
static void logmsg(const char *fmt, ...) {
    char ts[32]; time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tm);
    va_list ap; va_start(ap, fmt);
    fprintf(g_log, "%s [listener] ", ts); vfprintf(g_log, fmt, ap); fprintf(g_log, "\n"); fflush(g_log);
    va_end(ap);
}
static ssize_t writen(int fd, const void *buf, size_t n) {
    size_t left = n; const char *p = buf;
    while (left) { ssize_t w = write(fd, p, left); if (w < 0) { if (errno == EINTR) continue; return -1; } if (w == 0) return -1; left -= w; p += w; }
    return (ssize_t)n;
}
static ssize_t readn(int fd, void *buf, size_t n) {
    size_t left = n; char *p = buf;
    while (left) { ssize_t r = read(fd, p, left); if (r < 0) { if (errno == EINTR) continue; return -1; } if (r == 0) break; left -= r; p += r; }
    return (ssize_t)(n - left);
}
static void put64(unsigned char *b, uint64_t v) { for (int i = 7; i >= 0; i--) { b[i] = (unsigned char)(v & 0xff); v >>= 8; } }
static uint64_t get64(const unsigned char *b) { uint64_t v = 0; for (int i = 0; i < 8; i++) v = (v << 8) | b[i]; return v; }

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <port> <output_file> [log_file]\n", argv[0]); return 1; }
    int port = atoi(argv[1]); const char *outpath = argv[2];
    g_log = (argc >= 4) ? fopen(argv[3], "a") : stderr; if (!g_log) g_log = stderr;
    signal(SIGPIPE, SIG_IGN);

    int lst = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(lst, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a; memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_addr.s_addr = INADDR_ANY; a.sin_port = htons(port);
    if (bind(lst, (struct sockaddr *)&a, sizeof a) < 0) { logmsg("bind 실패 port=%d : %s", port, strerror(errno)); return 1; }
    listen(lst, 4);
    int outfd = open(outpath, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (outfd < 0) { logmsg("출력파일 열기 실패 %s : %s", outpath, strerror(errno)); return 1; }
    logmsg("시작 port=%d out=%s", port, outpath);

    char *buf = malloc(1 << 20);
    for (;;) {
        int c = accept(lst, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; logmsg("accept 오류 %s", strerror(errno)); continue; }
        unsigned char cmd;
        if (readn(c, &cmd, 1) != 1) { close(c); continue; }
        struct stat st; fstat(outfd, &st);
        unsigned char b8[8]; put64(b8, (uint64_t)st.st_size);
        if (writen(c, b8, 8) != 8) { close(c); continue; }

        if (cmd == 'D') {
            uint64_t got = 0; ssize_t r;
            while ((r = read(c, buf, 1 << 20)) > 0) {
                if (writen(outfd, buf, r) != r) { logmsg("파일 쓰기 오류 %s", strerror(errno)); break; }
                got += (uint64_t)r;
            }
            fstat(outfd, &st);
            logmsg("데이터 수신 %llu바이트, 파일 크기=%llu", (unsigned long long)got, (unsigned long long)st.st_size);
            close(c);
        } else if (cmd == 'F') {
            unsigned char e8[8]; if (readn(c, e8, 8) != 8) { close(c); continue; }
            uint64_t expected = get64(e8);
            fstat(outfd, &st); uint64_t cur = (uint64_t)st.st_size;
            unsigned char status = (cur == expected) ? 0 : 1;
            writen(c, &status, 1); close(c);
            if (status == 0) { logmsg("완료 검증 성공 size=%llu -> 종료", (unsigned long long)cur); break; }
            logmsg("완료 검증 불일치 expected=%llu got=%llu", (unsigned long long)expected, (unsigned long long)cur);
        } else { close(c); }
    }
    free(buf); close(outfd); close(lst); logmsg("종료");
    return 0;
}
