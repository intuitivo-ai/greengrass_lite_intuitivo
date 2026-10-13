/* A daemon that neither reads stdin nor cooperates with SIGTERM. */
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void exit_seven(int signal_number) {
    (void)signal_number;
    _exit(7);
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    signal(SIGTERM, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGUSR1, exit_seven);

    int fd = open(argv[1], O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return 3;
    dprintf(fd, "%d\n", getpid());
    close(fd);

    if (argc > 2 && (strcmp(argv[2], "output") == 0 || strcmp(argv[2], "config") == 0)) {
        for (int i = 0; i < 65536; i++) fputs("data\n", stdout);
        fputs("STDOUT_COMPLETE\n", stdout);
        fflush(stdout);
        fputs("STDERR_COMPLETE\n", stderr);
        fflush(stderr);
    }
    if (argc > 3 && strcmp(argv[2], "config") == 0) {
        int socket = open(argv[3], O_WRONLY | O_CREAT, 0600);
        if (socket < 0) return 4;
        close(socket);
    }
    if (argc > 2 && strcmp(argv[2], "chatty") == 0) {
        for (;;) {
            fputs("CONTINUOUS_OUTPUT\n", stdout);
            fflush(stdout);
            usleep(1000);
        }
    }
    for (;;) pause();
}
