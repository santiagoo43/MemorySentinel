#ifndef CSYSTEM_H
#define CSYSTEM_H
#include <stdint.h>
#include <sqlite3.h>
typedef struct {
 int32_t pid, ppid, pgid; uint32_t uid;
 uint64_t start_sec, start_usec, footprint, rss;
 int memory_valid;
 char name[64]; char path[4096];
} MSProcess;
typedef struct {
 uint64_t total, used, available, compressed, swap_used, disk_free;
 int vm_valid, swap_valid, disk_valid, pressure;
} MSSystem;
int ms_pids(int32_t *buffer, int capacity);
int ms_process(int32_t pid, MSProcess *result);
void ms_system(MSSystem *result);
int ms_process_exists(int32_t pid);
int ms_validate_target(int32_t pid, uint64_t sec, uint64_t usec, const char *path);
int ms_signal_checked(int32_t pid, uint64_t sec, uint64_t usec, const char *path, int signal_number);
/* One bounded local readiness exchange. No action or permission acquisition. */
int ms_cooperative_query(const char *path, int32_t pid, uint32_t uid,
 uint64_t sec, uint64_t usec, const char *request, char *response, int capacity);
#endif
