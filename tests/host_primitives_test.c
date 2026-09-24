/* tests/host_primitives_test.c — minimal C tests for the tether host surface.
 *
 * The mkdirp/fchmod/readdir/stat primitives, the krep_search grep backend and
 * the http_stream/http_get transport are statics inside src/host/main.c, so
 * this test pulls that translation unit in directly with `main` renamed away,
 * then drives the functions through a real Lua state exactly as the host
 * registers them (see open_tether_api). krep itself is linked in (see the
 * KREP_OBJS rule in the Makefile).
 * Run through `make test`.
 *
 * It deliberately does not use mkdtemp(): the test scratch dirs are derived
 * from the pid so no extra feature-test macros are needed after main.c is
 * included.
 */
#define main tether_host_main
#include "../src/host/main.c"
#undef main

#include <assert.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/wait.h>

static int failures = 0;

static void check(int cond, const char *what)
{
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", what);
        failures++;
    } else {
        printf("ok: %s\n", what);
    }
}

/* Print the Lua error on top of the stack and pop it. */
static void report_lua_error(lua_State *L, const char *name)
{
    fprintf(stderr, "FAIL: %s raised: %s\n", name,
            lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
    lua_pop(L, 1);
    failures++;
}

/* Push tether[name] then the single string argument; leave the result. */
static int call1(lua_State *L, const char *name, const char *arg)
{
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, name);
    lua_remove(L, -2);
    lua_pushstring(L, arg);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        report_lua_error(L, name);
        return 0;
    }
    return 1;
}

static int call_mkdirp(lua_State *L, const char *path)
{
    if (!call1(L, "mkdirp", path)) return 0;
    int ok = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return ok;
}

static int call_fchmod(lua_State *L, const char *path, int mode)
{
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "fchmod");
    lua_remove(L, -2);
    lua_pushstring(L, path);
    lua_pushinteger(L, mode);
    if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
        report_lua_error(L, "fchmod");
        return 0;
    }
    int ok = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return ok;
}

/* Push tether.krep_search(base, pattern, glob?, ignore_case, gitignore, max). */
static int call_krep_search(lua_State *L, const char *base, const char *pattern,
                            const char *glob, int ignore_case,
                            int use_gitignore, int max_results)
{
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "krep_search");
    lua_remove(L, -2);
    lua_pushstring(L, base);
    lua_pushstring(L, pattern);
    if (glob) lua_pushstring(L, glob);
    else lua_pushnil(L);
    lua_pushboolean(L, ignore_case);
    lua_pushboolean(L, use_gitignore);
    lua_pushinteger(L, max_results);
    if (lua_pcall(L, 6, 1, 0) != LUA_OK) {
        report_lua_error(L, "krep_search");
        return 0;
    }
    return 1;
}

/* Does the result array at `idx` contain a record whose path includes suffix? */
static int krep_has_path(lua_State *L, int idx, const char *suffix)
{
    int n = (int)lua_rawlen(L, idx);
    for (int i = 1; i <= n; i++) {
        lua_geti(L, idx, i);
        lua_getfield(L, -1, "path");
        const char *p = lua_tostring(L, -1);
        int hit = p != NULL && strstr(p, suffix) != NULL;
        lua_pop(L, 2);
        if (hit) return 1;
    }
    return 0;
}

static void write_str(const char *path, const char *content)
{
    FILE *f = fopen(path, "w");
    if (f != NULL) {
        fputs(content, f);
        fclose(f);
    }
}

/* T123 / task 2.1-2.3: the in-process krep backend honors .gitignore, the
   ignore_case flag, the glob filter and max_results, and returns
   {path, line, column, text} records. */
static void test_krep_search(lua_State *L)
{
    char kdir[256], asub[300], ak[400], aignored[400], asubf[400];
    char gitignore[400];
    snprintf(kdir, sizeof(kdir), "/tmp/tether_krep_test_%d", (int)getpid());
    snprintf(asub, sizeof(asub), "%s/sub", kdir);
    snprintf(ak, sizeof(ak), "%s/a.txt", kdir);
    snprintf(aignored, sizeof(aignored), "%s/ignored.txt", kdir);
    snprintf(asubf, sizeof(asubf), "%s/b.txt", asub);
    snprintf(gitignore, sizeof(gitignore), "%s/.gitignore", kdir);

    char cmd[600];
    snprintf(cmd, sizeof(cmd), "rm -rf %s", kdir);
    if (system(cmd) != 0) { /* nothing to remove */ }
    if (mkdir(kdir, 0777) != 0 || mkdir(asub, 0777) != 0) {
        failures++;
        fprintf(stderr, "FAIL: krep fixture setup\n");
        return;
    }
    write_str(ak, "NEEDLE one\nsecond line\n");
    write_str(aignored, "NEEDLE two\n");
    write_str(asubf, "needle three\n");
    write_str(gitignore, "ignored.txt\n");

    /* gitignore honored: ignored.txt is excluded even though it matches */
    if (call_krep_search(L, kdir, "NEEDLE", NULL, 0, 1, 100)) {
        check(lua_istable(L, -1), "krep_search returns a table");
        if (lua_istable(L, -1)) {
            check(krep_has_path(L, -1, "a.txt"), "krep search finds a.txt");
            check(!krep_has_path(L, -1, "ignored.txt"),
                  "krep honors .gitignore (ignored.txt excluded)");
            check(!krep_has_path(L, -1, "sub/b.txt"),
                  "krep is case-sensitive by default");
            /* record shape: {path, line, column, text} */
            lua_geti(L, -1, 1);
            if (lua_istable(L, -1)) {
                lua_getfield(L, -1, "line");
                check(lua_tointeger(L, -1) == 1, "krep record carries the line");
                lua_pop(L, 1);
                lua_getfield(L, -1, "column");
                check(lua_tointeger(L, -1) == 1, "krep record column defaults to 1");
                lua_pop(L, 1);
                lua_getfield(L, -1, "text");
                const char *text = lua_tostring(L, -1);
                check(text != NULL && strstr(text, "NEEDLE") != NULL,
                      "krep record carries the matched line text");
                lua_pop(L, 1);
            }
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    }

    /* with gitignore off the ignored file is searched again */
    if (call_krep_search(L, kdir, "NEEDLE", NULL, 0, 0, 100)) {
        if (lua_istable(L, -1))
            check(krep_has_path(L, -1, "ignored.txt"),
                  "krep searches .gitignore'd files when the flag is off");
        lua_pop(L, 1);
    }

    /* ignore_case reaches the case-insensitive subdirectory match */
    if (call_krep_search(L, kdir, "needle", NULL, 1, 1, 100)) {
        if (lua_istable(L, -1))
            check(krep_has_path(L, -1, "sub/b.txt"),
                  "krep ignore_case matches differently-cased lines");
        lua_pop(L, 1);
    }

    /* glob filter restricts the file set (krep --glob) */
    if (call_krep_search(L, kdir, "NEEDLE", "*.txt", 0, 1, 100)) {
        if (lua_istable(L, -1))
            check(krep_has_path(L, -1, "a.txt"), "krep glob filter keeps a.txt");
        lua_pop(L, 1);
    }
    if (call_krep_search(L, kdir, "needle", "*.lua", 1, 0, 100)) {
        if (lua_istable(L, -1))
            check((int)lua_rawlen(L, -1) == 0, "krep glob filter excludes non-matching files");
        lua_pop(L, 1);
    }

    /* max_results caps the returned record count */
    if (call_krep_search(L, kdir, "NEEDLE", NULL, 0, 0, 1)) {
        if (lua_istable(L, -1))
            check((int)lua_rawlen(L, -1) == 1, "krep_search honors max_results");
        lua_pop(L, 1);
    }

    /* file base: tools.grep passes the model's path straight through, so it
       is routinely a FILE. opendir on it failed ENOTDIR with the complaint
       going to the terminal (straight over the TUI) and zero records. */
    char errcap[400];
    snprintf(errcap, sizeof(errcap), "%s/stderr.cap", kdir);
    fflush(stderr);
    int saved_err = dup(STDERR_FILENO);
    int capfd = open(errcap, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (saved_err >= 0 && capfd >= 0)
        dup2(capfd, STDERR_FILENO);
    if (call_krep_search(L, ak, "NEEDLE", NULL, 0, 0, 100)) {
        if (lua_istable(L, -1)) {
            check((int)lua_rawlen(L, -1) == 1, "krep file base returns the match");
            check(krep_has_path(L, -1, "a.txt"),
                  "krep file base record names the file");
        }
        lua_pop(L, 1);
    }
    fflush(stderr);
    if (saved_err >= 0) { dup2(saved_err, STDERR_FILENO); close(saved_err); }
    if (capfd >= 0) close(capfd);
    FILE *ef = fopen(errcap, "r");
    int ech = ef ? fgetc(ef) : -1;
    if (ef) fclose(ef);
    check(ech == EOF, "krep keeps stderr silent (no TUI corruption)");

    snprintf(cmd, sizeof(cmd), "rm -rf %s", kdir);
    if (system(cmd) != 0) { /* best effort */ }
}

/* Read a string field off the table on top of the stack, then pop the table. */
static long table_int(lua_State *L, int idx, const char *field)
{
    lua_getfield(L, idx, field);
    long v = (long)lua_tointeger(L, -1);
    lua_pop(L, 1);
    return v;
}

static int table_bool(lua_State *L, int idx, const char *field)
{
    lua_getfield(L, idx, field);
    int v = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return v;
}

static int table_str_eq(lua_State *L, int idx, int i, const char *want)
{
    lua_geti(L, idx, i);
    const char *got = lua_tostring(L, -1);
    int ok = got && strcmp(got, want) == 0;
    if (!ok)
        fprintf(stderr, "FAIL: entry %d == %s (got %s)\n", i, want,
                got ? got : "nil");
    lua_pop(L, 1);
    return ok;
}

/* --- a throwaway loopback HTTP server for the transport tests --------------
 * Plain sockets, forked child, fixed number of requests. TLS cannot be
 * exercised here (no certificate authority), so only the HTTP framing,
 * streaming callback and status handling are covered. */

#define TEST_SERVER_REQUESTS 3

static pid_t start_test_server(int *out_port)
{
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0)
        return -1;
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(srv);
        return -1;
    }
    socklen_t alen = sizeof(addr);
    if (getsockname(srv, (struct sockaddr *)&addr, &alen) != 0 ||
        listen(srv, 8) != 0) {
        close(srv);
        return -1;
    }
    *out_port = ntohs(addr.sin_port);

    pid_t pid = fork();
    if (pid < 0) {
        close(srv);
        return -1;
    }
    if (pid == 0) {
        signal(SIGPIPE, SIG_IGN);
        for (int i = 0; i < TEST_SERVER_REQUESTS; i++) {
            int c = accept(srv, NULL, NULL);
            if (c < 0)
                break;
            char req[2048];
            ssize_t n = read(c, req, sizeof(req) - 1);
            if (n < 0)
                n = 0;
            req[n] = '\0';

            const char *status = "200 OK";
            const char *body = "data: one\n\ndata: two\n";
            if (strstr(req, "/models") != NULL)
                body = "{\"data\":[{\"id\":\"m1\"}]}";
            else if (strstr(req, "/missing") != NULL) {
                status = "404 Not Found";
                body = "nope";
            }

            char resp[1024];
            int len = snprintf(resp, sizeof(resp),
                "HTTP/1.1 %s\r\nContent-Type: application/json\r\n"
                "Content-Length: %zu\r\nConnection: close\r\n\r\n%s",
                status, strlen(body), body);
            if (len > 0) {
                ssize_t w = write(c, resp, (size_t)len);
                (void)w;
            }
            close(c);
        }
        close(srv);
        _exit(0);
    }
    return pid;
}

/* A server that streams one line and then pauses, repeatly, so a transfer stays
   in flight while the test writes a Ctrl+C to its own stdin. */
#define SLOW_SERVER_LINES 6
#define SLOW_SERVER_NAP_MS 200

static pid_t start_slow_server(int *out_port, const char *line, int lines)
{
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0)
        return -1;
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(srv, 4) != 0) {
        close(srv);
        return -1;
    }
    socklen_t alen = sizeof(addr);
    if (getsockname(srv, (struct sockaddr *)&addr, &alen) != 0) {
        close(srv);
        return -1;
    }
    *out_port = ntohs(addr.sin_port);

    pid_t pid = fork();
    if (pid < 0) {
        close(srv);
        return -1;
    }
    if (pid == 0) {
        signal(SIGPIPE, SIG_IGN);
        int c = accept(srv, NULL, NULL);
        if (c >= 0) {
            char req[2048];
            ssize_t n = read(c, req, sizeof(req) - 1);
            if (n < 0) n = 0;
            (void)n;
            char head[256];
            int hlen = snprintf(head, sizeof(head),
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                "Content-Length: %zu\r\nConnection: close\r\n\r\n",
                strlen(line) * (size_t)lines);
            if (hlen > 0 && write(c, head, (size_t)hlen) < 0) { /* gone */ }
            for (int i = 0; i < lines; i++) {
                if (write(c, line, strlen(line)) < 0)
                    break; /* the client aborted: stop streaming */
                struct timespec nap = { 0, SLOW_SERVER_NAP_MS * 1000 * 1000 };
                nanosleep(&nap, NULL);
            }
            close(c);
        }
        close(srv);
        _exit(0);
    }
    return pid;
}

static int g_stream_lines;
static char g_stream_first[256];
static char g_stream_second[256];

static int on_line_stub(lua_State *L)
{
    const char *line = lua_tostring(L, 1);
    if (line == NULL)
        line = "";
    if (g_stream_lines == 0)
        snprintf(g_stream_first, sizeof(g_stream_first), "%s", line);
    if (g_stream_lines == 1)
        snprintf(g_stream_second, sizeof(g_stream_second), "%s", line);
    g_stream_lines++;
    return 0;
}

/* Tasks 3.3/3.4: tether.http_get and tether.http_stream against a local
   server — full body on 200, "http <status>" on >= 400, and a per-line
   streaming callback that preserves blank SSE separators. */
static void test_http_transport(lua_State *L)
{
    int port = 0;
    pid_t pid = start_test_server(&port);
    if (pid <= 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot start the loopback HTTP test server\n");
        return;
    }
    char url[128];

    /* http_get: 200 -> the body */
    snprintf(url, sizeof(url), "http://127.0.0.1:%d/models", port);
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_get");
    lua_remove(L, -2);
    lua_pushstring(L, url);
    lua_newtable(L);
    lua_pushinteger(L, 30);
    if (lua_pcall(L, 3, 2, 0) != LUA_OK) {
        report_lua_error(L, "http_get");
    } else {
        const char *body = lua_tostring(L, -2);
        check(body != NULL && strstr(body, "\"m1\"") != NULL,
              "http_get returns the body on 200");
        lua_pop(L, 2);
    }

    /* http_get: >= 400 -> nil, "http <status>" */
    snprintf(url, sizeof(url), "http://127.0.0.1:%d/missing", port);
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_get");
    lua_remove(L, -2);
    lua_pushstring(L, url);
    lua_newtable(L);
    lua_pushinteger(L, 30);
    if (lua_pcall(L, 3, 2, 0) != LUA_OK) {
        report_lua_error(L, "http_get");
    } else {
        const char *err = lua_tostring(L, -1);
        check(lua_isnil(L, -2), "http_get returns nil on an HTTP error status");
        check(err != NULL && strcmp(err, "http 404") == 0,
              "http_get reports \"http 404\"");
        lua_pop(L, 2);
    }

    /* http_stream: on_line is called once per body line */
    snprintf(url, sizeof(url), "http://127.0.0.1:%d/stream", port);
    g_stream_lines = 0;
    g_stream_first[0] = '\0';
    g_stream_second[0] = '\0';
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_stream");
    lua_remove(L, -2);
    lua_pushstring(L, "POST");
    lua_pushstring(L, url);
    lua_newtable(L);                    /* headers */
    lua_pushnil(L);                     /* body */
    lua_pushcfunction(L, on_line_stub); /* on_line */
    lua_newtable(L);                    /* opts */
    if (lua_pcall(L, 6, 2, 0) != LUA_OK) {
        report_lua_error(L, "http_stream");
    } else {
        check(lua_toboolean(L, -2) == 1, "http_stream returns true");
        check(g_stream_lines == 3, "http_stream delivers every body line");
        check(strcmp(g_stream_first, "data: one") == 0,
              "http_stream passes the first line through");
        check(strcmp(g_stream_second, "") == 0,
              "http_stream keeps the blank SSE event boundary");
        lua_pop(L, 2);
    }

    int status = 0;
    waitpid(pid, &status, 0);
}

/* --- spinner tick rate during a silent stream ------------------------------
 * The server sends headers, then stays silent for TTFT_SILENCE_MS (a TTFT
 * stall), then sends one line. The tick hook must fire at ~80 ms all the
 * way through the silence: with curl_easy_perform the progress callback ran
 * only on network activity, so the spinner froze and jumped per batch. */
#define TTFT_SILENCE_MS 1200
#define TICK_TS_CAP 512

static double g_tick_ts[TICK_TS_CAP];
static int g_tick_n;

static double tick_clock_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static int tick_stub(lua_State *L)
{
    (void)L;
    if (g_tick_n < TICK_TS_CAP)
        g_tick_ts[g_tick_n++] = tick_clock_ms();
    return 0;
}

/* The blocking waits tick the hook the UI registers (tether.set_tick_hook);
   the tests bind the same seam instead of a global name. */
static void bind_tick_hook(lua_State *L, lua_CFunction fn)
{
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "set_tick_hook");
    lua_remove(L, -2);
    lua_pushcfunction(L, fn);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK)
        report_lua_error(L, "set_tick_hook");
}

static void clear_tick_hook(lua_State *L)
{
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "set_tick_hook");
    lua_remove(L, -2);
    lua_pushnil(L);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK)
        report_lua_error(L, "set_tick_hook(nil)");
}

static pid_t start_ttft_server(int *out_port)
{
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0)
        return -1;
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(srv, 4) != 0) {
        close(srv);
        return -1;
    }
    socklen_t alen = sizeof(addr);
    if (getsockname(srv, (struct sockaddr *)&addr, &alen) != 0) {
        close(srv);
        return -1;
    }
    *out_port = ntohs(addr.sin_port);

    pid_t pid = fork();
    if (pid < 0) {
        close(srv);
        return -1;
    }
    if (pid == 0) {
        signal(SIGPIPE, SIG_IGN);
        int c = accept(srv, NULL, NULL);
        if (c >= 0) {
            char req[2048];
            ssize_t n = read(c, req, sizeof(req) - 1);
            if (n < 0) n = 0;
            (void)n;
            const char *line = "data: late\n";
            char head[256];
            int hlen = snprintf(head, sizeof(head),
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                "Content-Length: %zu\r\nConnection: close\r\n\r\n",
                strlen(line));
            if (hlen > 0)
                write(c, head, (size_t)hlen);
            struct timespec nap = { TTFT_SILENCE_MS / 1000,
                                    (TTFT_SILENCE_MS % 1000) * 1000 * 1000 };
            nanosleep(&nap, NULL);
            write(c, line, strlen(line));
            close(c);
        }
        close(srv);
        _exit(0);
    }
    return pid;
}

static void test_spinner_tick_rate(lua_State *L)
{
    int port = 0;
    pid_t pid = start_ttft_server(&port);
    if (pid <= 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot start the TTFT test server\n");
        return;
    }
    char url[128];
    snprintf(url, sizeof(url), "http://127.0.0.1:%d/slow", port);
    g_tick_n = 0;
    bind_tick_hook(L, tick_stub);
    g_stream_lines = 0;
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_stream");
    lua_remove(L, -2);
    lua_pushstring(L, "POST");
    lua_pushstring(L, url);
    lua_newtable(L);
    lua_pushnil(L);
    lua_pushcfunction(L, on_line_stub);
    lua_newtable(L);
    if (lua_pcall(L, 6, 2, 0) != LUA_OK) {
        report_lua_error(L, "http_stream (ttft)");
    } else {
        check(lua_toboolean(L, -2) == 1, "http_stream survives a TTFT stall");
        check(g_stream_lines == 1, "http_stream delivers the late line");
        lua_pop(L, 2);
    }
    clear_tick_hook(L);

    /* ~1200 ms of silence at an 80 ms quantum: expect a steady tick train,
       not the 1-2 progress callbacks easy_perform delivered while idle. */
    check(g_tick_n >= 8, "spinner ticks through a silent stream");
    double worst_gap = 0;
    for (int i = 1; i < g_tick_n; i++) {
        double gap = g_tick_ts[i] - g_tick_ts[i - 1];
        if (gap > worst_gap)
            worst_gap = gap;
    }
    char gap_msg[128];
    snprintf(gap_msg, sizeof(gap_msg),
             "spinner tick gaps stay small (worst %.0f ms)", worst_gap);
    check(g_tick_n < 2 || worst_gap <= 400.0, gap_msg);

    int status = 0;
    waitpid(pid, &status, 0);
}

/* --- spinner tick rate during sleep ----------------------------------------
 * Retry backoff waits in tether.sleep with no transfer in flight, so the
 * multi-loop quantum never fires there: the spinner froze for the whole
 * wait. The sleep loop ticks on the same cadence instead. */
static void test_sleep_ticks(lua_State *L)
{
    g_tick_n = 0;
    bind_tick_hook(L, tick_stub);
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "sleep");
    lua_remove(L, -2);
    lua_pushnumber(L, 0.3);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
        report_lua_error(L, "sleep");
    } else {
        check(g_tick_n >= 2, "spinner ticks through a sleep (retry backoff)");
    }
    clear_tick_hook(L);
}

/* --- spinner tick rate during exec / http_get ------------------------------
 * The agent `run` tool blocks in tether.exec (up to 120 s) and a /models
 * refresh blocks in tether.http_get (up to 30 s): both froze the spinner
 * like the stream and the backoff did before them. */
static void test_exec_ticks(lua_State *L)
{
    g_tick_n = 0;
    bind_tick_hook(L, tick_stub);
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "exec");
    lua_remove(L, -2);
    lua_pushstring(L, "sleep 0.3");
    if (lua_pcall(L, 1, 2, 0) != LUA_OK) {
        report_lua_error(L, "exec");
    } else {
        check(lua_toboolean(L, -2) == 1, "tether.exec(sleep) still succeeds");
        check(lua_tointeger(L, -1) == 0, "tether.exec exit_code == 0");
        check(g_tick_n >= 2, "spinner ticks while a tool command runs");
        lua_pop(L, 2);
    }
    clear_tick_hook(L);
}

static void test_http_get_ticks(lua_State *L)
{
    int port = 0;
    pid_t pid = start_ttft_server(&port);
    if (pid <= 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot start the TTFT test server\n");
        return;
    }
    char url[128];
    snprintf(url, sizeof(url), "http://127.0.0.1:%d/slow", port);
    g_tick_n = 0;
    bind_tick_hook(L, tick_stub);
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_get");
    lua_remove(L, -2);
    lua_pushstring(L, url);
    lua_newtable(L);
    lua_pushinteger(L, 30);
    if (lua_pcall(L, 3, 2, 0) != LUA_OK) {
        report_lua_error(L, "http_get (ttft)");
    } else {
        const char *body = lua_tostring(L, -2);
        check(body != NULL && strstr(body, "data: late") != NULL,
              "http_get delivers the body after a TTFT stall");
        check(g_tick_n >= 8, "spinner ticks through a silent http_get");
        lua_pop(L, 2);
    }
    clear_tick_hook(L);

    int status = 0;
    waitpid(pid, &status, 0);
}

/* --- TLS: a peer certificate must chain to the system CA bundle -----------
 * `openssl s_server` serves a freshly generated self-signed certificate, so
 * the handshake must fail verification: the call returns nil, err and no body
 * is ever delivered. Skipped when the openssl CLI is absent (the system trust
 * store is a documented runtime requirement, not a build-time one). */

static int openssl_available(void)
{
    return system("command -v openssl >/dev/null 2>&1") == 0;
}

static int grab_free_port(void)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
        close(fd);
        return -1;
    }
    socklen_t len = sizeof(a);
    int port = -1;
    if (getsockname(fd, (struct sockaddr *)&a, &len) == 0)
        port = (int)ntohs(a.sin_port);
    close(fd);
    return port;
}

static int wait_for_port(int port, int tries)
{
    for (int i = 0; i < tries; i++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd >= 0) {
            struct sockaddr_in a;
            memset(&a, 0, sizeof(a));
            a.sin_family = AF_INET;
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            a.sin_port = htons((unsigned short)port);
            int ok = connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0;
            close(fd);
            if (ok)
                return 1;
        }
        struct timespec nap = { 0, 100 * 1000 * 1000 }; /* 100 ms */
        nanosleep(&nap, NULL);
    }
    return 0;
}

static void rm_rf(const char *path)
{
    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "rm -rf %s", path);
    if (system(cmd) != 0) { /* best effort */ }
}

static void test_tls_verification(lua_State *L)
{
    if (!openssl_available()) {
        printf("skip: TLS verification (openssl CLI not installed)\n");
        return;
    }

    char dir[256], cert[320], key[320], url[128], cmd[1400];
    snprintf(dir, sizeof(dir), "/tmp/tether_tls_test_%d", (int)getpid());
    snprintf(cert, sizeof(cert), "%s/cert.pem", dir);
    snprintf(key, sizeof(key), "%s/key.pem", dir);
    snprintf(cmd, sizeof(cmd),
             "rm -rf %s && mkdir -p %s && openssl req -x509 -newkey rsa:2048 "
             "-nodes -days 1 -subj /CN=127.0.0.1 -keyout %s -out %s "
             ">/dev/null 2>&1",
             dir, dir, key, cert);
    if (system(cmd) != 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot generate a self-signed test certificate\n");
        return;
    }

    int port = grab_free_port();
    if (port <= 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot reserve a loopback port for the TLS server\n");
        return;
    }
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);

    pid_t pid = fork();
    if (pid < 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot fork the TLS test server\n");
        return;
    }
    if (pid == 0) {
        signal(SIGPIPE, SIG_IGN);
        execlp("openssl", "openssl", "s_server", "-quiet", "-accept", portstr,
               "-cert", cert, "-key", key, "-www", (char *)NULL);
        _exit(127);
    }

    if (!wait_for_port(port, 50)) {
        failures++;
        fprintf(stderr, "FAIL: the TLS test server never accepted connections\n");
        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
        rm_rf(dir);
        return;
    }

    snprintf(url, sizeof(url), "https://127.0.0.1:%d/", port);
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_get");
    lua_remove(L, -2);
    lua_pushstring(L, url);
    lua_newtable(L);
    lua_pushinteger(L, 5);
    if (lua_pcall(L, 3, 2, 0) != LUA_OK) {
        report_lua_error(L, "http_get");
    } else {
        const char *err = lua_tostring(L, -1);
        check(lua_isnil(L, -2), "TLS: a self-signed peer yields no body");
        check(err != NULL && strstr(err, "connect") == NULL,
              "TLS: the failure is a verification error, not a connection error");
        lua_pop(L, 2);
    }

    kill(pid, SIGTERM);
    waitpid(pid, NULL, 0);
    rm_rf(dir);
}

/* --- Ctrl+C while a turn blocks -------------------------------------------
 * Raw mode clears ISIG, so an in-terminal Ctrl+C reaches the process as byte
 * 0x03, and the UI reads stdin only between turns — exactly when no turn is
 * running. These tests pin the host side of the fix: while a turn blocks the
 * host watches stdin itself, 0x03 raises the interrupt, every other byte is
 * queued for read_char, and tether.sleep returns as soon as the interrupt
 * arrives instead of sleeping out the whole backoff. */

static double now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* Call tether.<name>() with no arguments and return its first result. */
static int call0(lua_State *L, const char *name)
{
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, name);
    lua_remove(L, -2);
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        report_lua_error(L, name);
        return 0;
    }
    return 1;
}

/* A Ctrl+C during an in-flight transfer must abort it: the progress callback
   watches stdin, so the turn ends when the user asks rather than when the
   provider's stream happens to finish. The server streams for ~1.2 s, so an
   abort that is seen within ~0.5 s is unambiguous. */
static void test_interrupt_aborts_transfer(lua_State *L)
{
    const char *line = "data: {\"x\":1}\n";
    int port = 0;
    pid_t server = start_slow_server(&port, line, SLOW_SERVER_LINES);
    if (server <= 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot start the slow HTTP test server\n");
        return;
    }

    int fds[2];
    if (pipe(fds) != 0 || dup2(fds[0], STDIN_FILENO) < 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot point stdin at the interrupt test pipe\n");
        return;
    }
    close(fds[0]);
    g_interrupt = 0;
    g_stdin_eof = 0;
    g_pending_len = g_pending_pos = 0;

    pid_t writer = fork();
    if (writer == 0) {
        struct timespec nap = { 0, 300 * 1000 * 1000 }; /* 300 ms */
        nanosleep(&nap, NULL);
        if (write(fds[1], "\003", 1) < 0) { /* parent already gone */ }
        _exit(0);
    }

    char url[128];
    snprintf(url, sizeof(url), "http://127.0.0.1:%d/stream", port);
    g_stream_lines = 0;
    double t0 = now_seconds();
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_stream");
    lua_remove(L, -2);
    lua_pushstring(L, "POST");
    lua_pushstring(L, url);
    lua_newtable(L);                    /* headers */
    lua_pushnil(L);                     /* body */
    lua_pushcfunction(L, on_line_stub); /* on_line */
    lua_newtable(L);                    /* opts */
    int rc = lua_pcall(L, 6, 2, 0);
    double elapsed = now_seconds() - t0;
    if (rc != LUA_OK) {
        report_lua_error(L, "http_stream");
    } else {
        const char *err = lua_tostring(L, -1);
        check(lua_isnil(L, -2), "an interrupted transfer delivers no success");
        check(err != NULL, "an interrupted transfer reports an error");
        lua_pop(L, 2);
    }
    check(elapsed < 1.0, "Ctrl+C aborts a transfer while it is in flight");
    check(g_stream_lines < SLOW_SERVER_LINES,
          "the aborted transfer stops delivering lines");

    if (writer > 0) {
        int status = 0;
        waitpid(writer, &status, 0);
    }
    kill(server, SIGKILL);
    int status = 0;
    waitpid(server, &status, 0);
    close(fds[1]);
    if (call0(L, "clear_abort")) lua_pop(L, 1);
    int devnull = open("/dev/null", O_RDONLY);
    if (devnull >= 0) {
        if (dup2(devnull, STDIN_FILENO) < 0) { /* best effort */ }
        close(devnull);
    }
}

static void test_interrupt_watch(lua_State *L)
{
    int fds[2];
    if (pipe(fds) != 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot create the interrupt test pipe\n");
        return;
    }
    if (dup2(fds[0], STDIN_FILENO) < 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot point stdin at the test pipe\n");
        close(fds[0]);
        close(fds[1]);
        return;
    }
    close(fds[0]); /* the writer fd stays open: stdin must not hit EOF */

    /* a byte stream with the Ctrl+C in the middle */
    const char payload[] = { 'a', 'b', 3, 'c' };
    if (write(fds[1], payload, sizeof(payload)) < 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot write the interrupt payload\n");
    }
    g_interrupt = 0;
    g_stdin_eof = 0;
    g_pending_len = g_pending_pos = 0;

    check(poll_interrupt() == 1, "the host watch notices Ctrl+C while a turn blocks");

    unsigned char b = 0;
    check(pending_take(&b) && b == 'a', "a keystroke typed during a turn is queued");
    check(pending_take(&b) && b == 'b', "every ordinary byte is queued in order");
    check(pending_take(&b) && b == 'c', "queued input survives the interrupt");
    check(!pending_take(&b), "the Ctrl+C byte is not replayed as input");

    /* The flag stays set until clear_abort: the same Ctrl+C keeps aborting an
       in-flight transfer until the turn has actually stopped. */
    if (call0(L, "abort_requested")) {
        check(lua_toboolean(L, -1) == 1, "tether.abort_requested reports the Ctrl+C");
        lua_pop(L, 1);
    }
    if (call0(L, "abort_requested")) {
        check(lua_toboolean(L, -1) == 1,
              "tether.abort_requested stays set until it is cleared");
        lua_pop(L, 1);
    }
    if (call0(L, "clear_abort")) lua_pop(L, 1);
    if (call0(L, "abort_requested")) {
        check(lua_toboolean(L, -1) == 0, "tether.clear_abort clears the interrupt");
        lua_pop(L, 1);
    }

    /* tether.sleep: a Ctrl+C mid-wait ends the wait instead of outlasting it */
    pid_t writer = fork();
    if (writer == 0) {
        struct timespec nap = { 0, 200 * 1000 * 1000 }; /* 200 ms */
        nanosleep(&nap, NULL);
        if (write(fds[1], "\003", 1) < 0) { /* parent already gone */ }
        _exit(0);
    }
    if (writer < 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot fork the Ctrl+C writer\n");
    } else {
        double t0 = now_seconds();
        lua_getglobal(L, "tether");
        lua_getfield(L, -1, "sleep");
        lua_remove(L, -2);
        lua_pushnumber(L, 1.0);
        if (lua_pcall(L, 1, 0, 0) != LUA_OK)
            report_lua_error(L, "sleep");
        double waited = now_seconds() - t0;
        check(waited < 0.8, "tether.sleep wakes when Ctrl+C arrives mid-wait");
        check(waited > 0.15, "tether.sleep still waits while nothing arrives");
        if (call0(L, "abort_requested")) {
            check(lua_toboolean(L, -1) == 1,
                  "the interrupt survives the wait for the agent to read");
            lua_pop(L, 1);
        }
        int status = 0;
        waitpid(writer, &status, 0);
    }

    /* an interrupt delivered while nothing is waiting must not leak into the
       next turn: clear_abort drops it */
    g_interrupt = 1;
    if (call0(L, "clear_abort")) lua_pop(L, 1);
    check(g_interrupt == 0, "tether.clear_abort drops a stale interrupt");

    close(fds[1]);
    int devnull = open("/dev/null", O_RDONLY);
    if (devnull >= 0) {
        if (dup2(devnull, STDIN_FILENO) < 0) { /* best effort */ }
        close(devnull);
    }
}

/* --- incremental transfers for the reactor ----------------------------------
 * tether.http_start/step/lines/abort/free/fds + tether.poll against a local
 * server: a stepped transfer delivers the same lines as http_stream
 * (including the blank SSE boundary and the trailing line), abort ends it
 * as a failure, and poll reports no stdin wait. */
static void test_http_xfer_steps(lua_State *L)
{
    int port = 0;
    pid_t pid = start_test_server(&port);
    if (pid <= 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot start the loopback HTTP test server\n");
        return;
    }
    char url[128];
    snprintf(url, sizeof(url), "http://127.0.0.1:%d/stream", port);

    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_start");
    lua_remove(L, -2);
    lua_pushstring(L, "POST");
    lua_pushstring(L, url);
    lua_newtable(L);
    lua_pushnil(L);
    lua_newtable(L);
    if (lua_pcall(L, 5, 2, 0) != LUA_OK) {
        report_lua_error(L, "http_start");
        goto xfer_done;
    }
    if (lua_isnil(L, -2)) {
        char msg[256];
        snprintf(msg, sizeof(msg), "http_start failed: %s",
                 lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
        check(0, msg);
        lua_pop(L, 2);
        goto xfer_done;
    }
    lua_pop(L, 1); /* drop nil error slot */
    check(luaL_testudata(L, -1, "tether.http_xfer") != NULL,
          "http_start returns a transfer handle");
    int hidx = lua_gettop(L);

    /* fds for the reactor poll exist from the start */
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_fds");
    lua_remove(L, -2);
    lua_pushvalue(L, hidx);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        report_lua_error(L, "http_fds");
    } else {
        lua_getfield(L, -1, "timeout");
        check(lua_isnumber(L, -1), "http_fds reports a poll timeout");
        lua_pop(L, 2);
    }

    /* step until done, draining lines on every step */
    char collected[1024];
    collected[0] = '\0';
    int nsteps = 0;
    const char *status = "running";
    while (nsteps < 200) {
        lua_getglobal(L, "tether");
        lua_getfield(L, -1, "http_step");
        lua_remove(L, -2);
        lua_pushvalue(L, hidx);
        lua_pushinteger(L, 100);
        if (lua_pcall(L, 2, 2, 0) != LUA_OK) {
            report_lua_error(L, "http_step");
            break;
        }
        status = lua_tostring(L, -2);
        if (status == NULL)
            status = "?";
        lua_pop(L, 2);
        nsteps++;
        lua_getglobal(L, "tether");
        lua_getfield(L, -1, "http_lines");
        lua_remove(L, -2);
        lua_pushvalue(L, hidx);
        if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
            report_lua_error(L, "http_lines");
            break;
        }
        size_t n = lua_rawlen(L, -1);
        for (size_t i = 1; i <= n; i++) {
            lua_geti(L, -1, (lua_Integer)i);
            const char *ln = lua_tostring(L, -1);
            if (ln != NULL) {
                strncat(collected, ln,
                        sizeof(collected) - strlen(collected) - 1);
                strncat(collected, "|",
                        sizeof(collected) - strlen(collected) - 1);
            }
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
        if (strcmp(status, "done") == 0 || strcmp(status, "failed") == 0)
            break;
    }
    check(strcmp(status, "done") == 0, "a stepped transfer finishes as done");
    check(strcmp(collected, "data: one||data: two|") == 0,
          "stepped lines match http_stream framing");
    /* stepping a finished handle repeats the terminal status */
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_step");
    lua_remove(L, -2);
    lua_pushvalue(L, hidx);
    lua_pushinteger(L, 10);
    if (lua_pcall(L, 2, 2, 0) != LUA_OK) {
        report_lua_error(L, "http_step (repeat)");
    } else {
        check(strcmp(lua_tostring(L, -2), "done") == 0,
              "stepping a finished transfer repeats done");
        lua_pop(L, 2);
    }
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_free");
    lua_remove(L, -2);
    lua_pushvalue(L, hidx);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK)
        report_lua_error(L, "http_free");
    else
        lua_pop(L, 1);
    lua_pop(L, 1); /* handle */

xfer_done:;
    /* the shared fixture server serves a fixed request count; this test
       makes only one, so reap by signal instead of waiting for exit. */
    kill(pid, SIGKILL);
    int st = 0;
    waitpid(pid, &st, 0);
}

/* Abort on the reactor path: http_abort ends an in-flight transfer as a
 * failure on the next step, without touching stdin. */
static void test_http_xfer_abort(lua_State *L)
{
    const char *line = "data: {\"x\":1}\n";
    int port = 0;
    pid_t server = start_slow_server(&port, line, SLOW_SERVER_LINES);
    if (server <= 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot start the slow HTTP test server\n");
        return;
    }
    char url[128];
    snprintf(url, sizeof(url), "http://127.0.0.1:%d/stream", port);
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_start");
    lua_remove(L, -2);
    lua_pushstring(L, "POST");
    lua_pushstring(L, url);
    lua_newtable(L);
    lua_pushnil(L);
    lua_newtable(L);
    if (lua_pcall(L, 5, 2, 0) != LUA_OK) {
        report_lua_error(L, "http_start (abort)");
        goto abort_done;
    }
    if (lua_isnil(L, -2)) {
        lua_pop(L, 2);
        check(0, "http_start failed for the abort test");
        goto abort_done;
    }
    lua_pop(L, 1);
    int hidx = lua_gettop(L);
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_abort");
    lua_remove(L, -2);
    lua_pushvalue(L, hidx);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        report_lua_error(L, "http_abort");
    } else {
        lua_pop(L, 1);
    }
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_step");
    lua_remove(L, -2);
    lua_pushvalue(L, hidx);
    lua_pushinteger(L, 500);
    if (lua_pcall(L, 2, 2, 0) != LUA_OK) {
        report_lua_error(L, "http_step (abort)");
    } else {
        check(strcmp(lua_tostring(L, -2), "failed") == 0,
              "an aborted transfer steps as failed");
        lua_pop(L, 2);
    }
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "http_free");
    lua_remove(L, -2);
    lua_pushvalue(L, hidx);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK)
        report_lua_error(L, "http_free (abort)");
    else
        lua_pop(L, 1);
    lua_pop(L, 1);

abort_done:;
    kill(server, SIGKILL);
    int st = 0;
    waitpid(server, &st, 0);
}

/* tether.poll waits on the given descriptors with a bounded timeout and
 * reports readiness without touching Lua input state. */
static void test_poll_primitive(lua_State *L)
{
    lua_getglobal(L, "tether");
    lua_getfield(L, -1, "poll");
    lua_remove(L, -2);
    lua_newtable(L);
    lua_newtable(L);
    lua_pushinteger(L, 20);
    double t0 = now_seconds();
    if (lua_pcall(L, 3, 1, 0) != LUA_OK) {
        report_lua_error(L, "poll");
        return;
    }
    double waited = now_seconds() - t0;
    check(lua_istable(L, -1), "tether.poll returns a readiness table");
    lua_getfield(L, -1, "read");
    int nread = (int)lua_rawlen(L, -1);
    lua_pop(L, 1);
    check(nread == 0, "tether.poll reports no readiness on empty sets");
    check(waited < 1.0, "tether.poll honors its timeout");
    lua_pop(L, 1);
}

/* read_char_nb is a pure non-blocking drain: with stdin idle (an open pipe,
 * no data, no EOF) it returns nil at once instead of sitting out the 50 ms
 * select the pre-reactor primitive waited. Readiness waiting belongs to
 * tether.poll, so no pump or timer callback can stall on input. */
static void test_read_char_nb_never_waits(lua_State *L)
{
    int fds[2];
    if (pipe(fds) != 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot create the read_char_nb pipe\n");
        return;
    }
    if (dup2(fds[0], STDIN_FILENO) < 0) {
        failures++;
        fprintf(stderr, "FAIL: cannot point stdin at the read_char_nb pipe\n");
        close(fds[0]);
        close(fds[1]);
        return;
    }
    close(fds[0]); /* the writer stays open: idle, but no EOF */
    g_interrupt = 0;
    g_stdin_eof = 0;
    g_pending_len = g_pending_pos = 0;

    /* The old primitive waited 50 ms per call; four of those are 200 ms, so
       the bound below cannot pass if the wait ever comes back. */
    int i, nils = 0;
    double t0 = now_seconds();
    for (i = 0; i < 4; i++) {
        if (call0(L, "read_char_nb")) {
            nils += lua_isnil(L, -1);
            lua_pop(L, 1);
        }
    }
    double waited = now_seconds() - t0;
    check(nils == 4, "read_char_nb yields nil while no byte is ready");
    check(waited < 0.1, "read_char_nb never waits on an idle stdin");

    /* a byte that is already available comes back, also without waiting */
    if (write(fds[1], "x", 1) != 1) {
        failures++;
        fprintf(stderr, "FAIL: cannot write to the read_char_nb pipe\n");
    } else {
        int got = 0;
        t0 = now_seconds();
        if (call0(L, "read_char_nb")) {
            got = lua_tointeger(L, -1) == 'x';
            lua_pop(L, 1);
        }
        check(got, "read_char_nb hands back a ready byte");
        check(now_seconds() - t0 < 0.1,
              "read_char_nb reads a ready byte without waiting");
    }

    close(fds[1]);
    int devnull = open("/dev/null", O_RDONLY);
    if (devnull >= 0) {
        if (dup2(devnull, STDIN_FILENO) < 0) { /* best effort */ }
        close(devnull);
    }
}

int main(void)
{
    char dir[256], nested[512], f1[512], f2[512];
    snprintf(dir, sizeof(dir), "/tmp/tether_fs_test_%d", (int)getpid());
    snprintf(nested, sizeof(nested), "%s/a/b/c", dir);
    snprintf(f1, sizeof(f1), "%s/beta.txt", dir);
    snprintf(f2, sizeof(f2), "%s/alpha.txt", dir);

    char cmd[600];
    snprintf(cmd, sizeof(cmd), "rm -rf %s", dir);
    if (system(cmd) != 0) { /* nothing to clean */ }

    lua_State *L = luaL_newstate();
    if (L == NULL) {
        fprintf(stderr, "FAIL: cannot create lua state\n");
        return 1;
    }
    luaL_openlibs(L);
    open_tether_api(L);

    /* --- mkdirp ---------------------------------------------------------- */
    check(call_mkdirp(L, nested), "tether.mkdirp creates a nested tree");
    struct stat st;
    check(stat(nested, &st) == 0 && S_ISDIR(st.st_mode),
          "mkdirp produced an actual directory");
    check(call_mkdirp(L, nested), "tether.mkdirp is idempotent (EEXIST ok)");
    check(!call_mkdirp(L, ""), "tether.mkdirp rejects an empty path");
    /* a path that already exists as a *file* is not a directory */
    FILE *fh = fopen(f1, "w");
    check(fh != NULL, "test fixture file created");
    if (fh) { fputs("x", fh); fclose(fh); }
    check(!call_mkdirp(L, f1), "tether.mkdirp rejects a path that is a file");

    fh = fopen(f2, "w");
    if (fh) { fputs("y", fh); fclose(fh); }

    /* --- readdir --------------------------------------------------------- */
    if (call1(L, "readdir", dir)) {
        check(lua_istable(L, -1), "tether.readdir returns a table");
        /* entries: a, alpha.txt, beta.txt — sorted, no . or .. */
        if (lua_istable(L, -1)) {
            failures += !table_str_eq(L, -1, 1, "a");
            failures += !table_str_eq(L, -1, 2, "alpha.txt");
            failures += !table_str_eq(L, -1, 3, "beta.txt");
            lua_geti(L, -1, 4);
            check(lua_isnil(L, -1), "readdir has no 4th entry");
            lua_pop(L, 1);
            int i;
            for (i = 1; i <= 3; i++) {
                lua_geti(L, -1, i);
                const char *n = lua_tostring(L, -1);
                failures += (n && (strcmp(n, ".") == 0 || strcmp(n, "..") == 0));
                lua_pop(L, 1);
            }
            check(1, "readdir omits . and ..");
        }
        lua_pop(L, 1);
    }
    if (call1(L, "readdir", "/no/such/dir/for-tether-fs-test")) {
        check(lua_isnil(L, -1), "tether.readdir returns nil for a missing dir");
        lua_pop(L, 1);
    }

    /* --- stat ------------------------------------------------------------ */
    if (call1(L, "stat", f1)) {
        check(lua_istable(L, -1), "tether.stat returns a table");
        if (lua_istable(L, -1)) {
            check(table_bool(L, -1, "is_dir") == 0, "stat: file is_dir == false");
            check(table_int(L, -1, "size") == 1, "stat: file size == 1");
            check(table_int(L, -1, "mtime") > 0, "stat: file mtime is set");
        }
        lua_pop(L, 1);
    }
    if (call1(L, "stat", nested)) {
        if (lua_istable(L, -1))
            check(table_bool(L, -1, "is_dir") == 1, "stat: dir is_dir == true");
        lua_pop(L, 1);
    }
    if (call1(L, "stat", "/no/such/file/for-tether-fs-test")) {
        check(lua_isnil(L, -1), "tether.stat returns nil for a missing path");
        lua_pop(L, 1);
    }

    /* --- fchmod ---------------------------------------------------------- */
    check(call_fchmod(L, f1, 0600), "tether.fchmod reports success");
    struct stat s2;
    check(stat(f1, &s2) == 0 && (s2.st_mode & 0777) == 0600,
          "fchmod applied mode 0600");
    check(!call_fchmod(L, "/no/such/file/for-tether-fs-test", 0600),
          "tether.fchmod fails on a missing file");

    /* --- exec / SIGCHLD -------------------------------------------------- */
    /* Audit blocker: SIG_IGN for SIGCHLD makes system() fail with ECHILD and
       every shell tool report exit 255 even on success. Any regression in the
       signal setup shows up here. */
    {
        lua_getglobal(L, "tether");
        lua_getfield(L, -1, "exec");
        lua_remove(L, -2);
        lua_pushstring(L, "true");
        check(lua_pcall(L, 1, 2, 0) == LUA_OK, "tether.exec runs");
        check(lua_toboolean(L, -2) == 1,
              "tether.exec(\"true\") reports success (SIGCHLD not SIG_IGN)");
        check(lua_tointeger(L, -1) == 0, "tether.exec exit_code == 0");
        lua_pop(L, 2);
    }

    test_krep_search(L);
    test_http_transport(L);
    test_http_xfer_steps(L);
    test_http_xfer_abort(L);
    test_poll_primitive(L);
    test_read_char_nb_never_waits(L);
    test_spinner_tick_rate(L);
    test_sleep_ticks(L);
    test_exec_ticks(L);
    test_http_get_ticks(L);
    test_tls_verification(L);
    test_interrupt_watch(L);
    test_interrupt_aborts_transfer(L);

    lua_close(L);

    snprintf(cmd, sizeof(cmd), "rm -rf %s", dir);
    if (system(cmd) != 0) { /* best effort */ }

    if (failures > 0) {
        fprintf(stderr, "HOST PRIMITIVES FAIL: %d check(s)\n", failures);
        return 1;
    }
    printf("HOST PRIMITIVES PASS\n");
    return 0;
}
