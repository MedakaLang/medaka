#ifndef MEDAKA_RUNTIME_H
#define MEDAKA_RUNTIME_H

#include "medaka_abi.h"

void *mdk_alloc(long long n);
long long mdk_none(void);
long long mdk_some(long long value);
long long mdk_ok(long long value);
long long mdk_err(long long value);
long long mdk_runtime_string(const char *value);

#endif
