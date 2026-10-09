#pragma once

#include <sys/types.h>
#include <sys/socket.h>
#if !defined(__linux__)
#include <sys/statvfs.h>
#endif
#include <sys/utsname.h>
#include <netinet/in.h>
#include <ifaddrs.h>
#include <arpa/inet.h>

#if defined(__APPLE__)
#include <sys/time.h>
#include <sys/sysctl.h>
#include <sys/mount.h>
#elif defined(__FreeBSD__)
#include <sys/sysctl.h>
#endif
