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

    test_krep_search(L);
    test_http_transport(L);
    test_tls_verification(L);

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
