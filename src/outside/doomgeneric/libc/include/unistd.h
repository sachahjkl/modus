#ifndef _UNISTD_H
#define _UNISTD_H

#include <stddef.h>
#include <sys/types.h>

#define F_OK 0
#define R_OK 4
#define W_OK 2

int access(const char *path, int mode);
int isatty(int fd);

#endif
