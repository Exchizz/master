#include <unistd.h>
#include <errno.h>
#include <stdio.h>
// Must use Linux specific fcntl header.
#include </usr/include/linux/fcntl.h>

int main(int argc, char *argv[]) {
    if (argc > 2) {
        printf("Usage: %s [fifo]\n\n"
                "Test get and set pipe buffer size\n",
                argv[0]);
        return 1;
    }

    int fd = 0; // Default to stdin, so we can test fcntl over pipe.

    printf("Pagesize: %d\n", getpagesize());
    printf("Validating parameters\n");
    if (argc == 2) {
        // The specified file should be a fifo.
        fd = open(argv[1], O_RDONLY | O_NONBLOCK);
        if (fd < 0) {
            perror("open failed");
            return 1;
        }
	printf("fd of pipe: %d\n", fd);
    }
    printf("Getting size\n");
    
    long pipe_size = (long)fcntl(fd, F_GETPIPE_SZ);
    if (pipe_size == -1) {
        perror("get pipe size failed.");
    }
    printf("pipe size: %ld\n", pipe_size);

    int ret = fcntl(fd, F_SETPIPE_SZ, 4096);
    if (ret < 0) {
        perror("set pipe size failed.");
    }

    pipe_size = (long)fcntl(fd, F_GETPIPE_SZ);
    if (pipe_size == -1) {
        perror("get pipe size 2 failed.");
    }
    printf("new pipe size: %ld\n", pipe_size);

    close(fd);
}
