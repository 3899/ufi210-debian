// SPDX-License-Identifier: MIT

#define _GNU_SOURCE

#include <errno.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static void usage(const char *program)
{
	fprintf(stderr, "用法：%s [bootloader|recovery]\n", program);
}

int main(int argc, char **argv)
{
	const char *mode = NULL;
	int command = LINUX_REBOOT_CMD_RESTART;

	if (argc > 2) {
		usage(argv[0]);
		return 2;
	}

	if (argc == 2) {
		if (strcmp(argv[1], "bootloader") != 0 &&
		    strcmp(argv[1], "recovery") != 0) {
			usage(argv[0]);
			return 2;
		}

		mode = argv[1];
		command = LINUX_REBOOT_CMD_RESTART2;
	}

	if (geteuid() != 0) {
		fprintf(stderr, "%s：需要 root 权限\n", argv[0]);
		return 1;
	}

	sync();
	if (syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		    command, mode) == -1) {
		fprintf(stderr, "%s：reboot 失败：%s\n", argv[0], strerror(errno));
		return 1;
	}

	return 0;
}
