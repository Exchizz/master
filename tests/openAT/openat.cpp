#include <iostream>
#include <cstdio>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

int main(){
	int fd = open("/tmp/",O_PATH|O_DIRECTORY);
	int retval = openat(fd,"test",O_PATH|O_DIRECTORY);
	std::cout << "retval: " << retval << std::endl;
	printf("%m\n");
	retval = mkdirat(fd, "somedir",0750);
	printf("%m\n");
	while(true){
		usleep(100000);
	}

	close(fd);
	return 0;
}
