/* tether M1: C host, raw-mode terminal, echo loop */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <termios.h>

static struct termios orig_termios;

static void restore_termios(void)
{
    tcsetattr(STDIN_FILENO, TCSANOW, &orig_termios);
    printf("\x1b[?25h");
    printf("\n");
    fflush(stdout);
}

static void on_sigterm(int sig)
{
    (void)sig;
    restore_termios();
    _exit(0);
}

static int init_termios(void)
{
    struct termios raw;
    if (tcgetattr(STDIN_FILENO, &orig_termios) == -1)
        return -1;
    raw = orig_termios;
    raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= ~OPOST;
    raw.c_cflag |= CS8;
    raw.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == -1)
        return -1;
    return 0;
}

static void drain_escape(void)
{
    /* consume an ESC sequence: read until final byte not in [A-Za-z] */
    char buf[8];
    ssize_t n = read(STDIN_FILENO, &buf[0], 1);
    if (n != 1)
        return;
    if (buf[0] != '[' && buf[0] != 'O')
        return;
    n = read(STDIN_FILENO, &buf[1], 1);
    if (n != 1)
        return;
    char c = buf[1];
    while (c >= 'A' && c <= 'Z') {
        n = read(STDIN_FILENO, &c, 1);
        if (n != 1)
            break;
    }
}

static int is_tty_stdin(void)
{
    return isatty(STDIN_FILENO) == 1;
}

int main(void)
{
    int interactive = is_tty_stdin();

    if (interactive) {
        if (init_termios() != 0) {
            perror("tcgetattr");
            return 1;
        }
        atexit(restore_termios);
        signal(SIGTERM, on_sigterm);
        printf("tether\n");
        fflush(stdout);
    }

    char c;
    for (;;) {
        ssize_t n = read(STDIN_FILENO, &c, 1);
        if (n == 0 || n == -1) {
            /* EOF or error: clean exit */
            return 0;
        }
        unsigned char uc = (unsigned char)c;
        switch (uc) {
        case 3:   /* Ctrl+C */
        case 4:   /* Ctrl+D */
        case 24:  /* Ctrl+X */
            return 0;
        case 12:  /* Ctrl+L */
            if (interactive)
                printf("\x1b[2J\x1b[H");
            break;
        case 27:  /* ESC - drain arrow/function key sequences */
            if (interactive)
                drain_escape();
            break;
        case 127: /* backspace */
        case 8:
            if (interactive)
                printf("\b \b");
            break;
        case 1:   /* Ctrl+A - echo as ^A */
        case 2:   /* Ctrl+B */
        case 5:   /* Ctrl+E */
        case 6:   /* Ctrl+F */
        case 7:   /* Ctrl+G */
        case 11:  /* Ctrl+K */
        case 13:  /* Ctrl+M */
        case 14:  /* Ctrl+N */
        case 15:  /* Ctrl+O */
        case 16:  /* Ctrl+P */
        case 17:  /* Ctrl+Q */
        case 18:  /* Ctrl+R */
        case 19:  /* Ctrl+S */
        case 20:  /* Ctrl+T */
        case 21:  /* Ctrl+U */
        case 22:  /* Ctrl+V */
        case 23:  /* Ctrl+W */
        case 25:  /* Ctrl+Y */
        case 26:  /* Ctrl+Z */
        case 28:  /* Ctrl+\ */
            if (interactive)
                printf("^%c", uc + 'A' - 1);
            break;
        default:
            if (uc >= 32 && uc <= 126) {
                if (interactive)
                    printf("%c", uc);
            }
            break;
        }
        if (interactive)
            fflush(stdout);
    }
}
