#include "CSystem.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/statvfs.h>
#include <mach/mach.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
int ms_pids(int32_t *buffer, int capacity) {
 int n = proc_listpids(PROC_ALL_PIDS, 0, buffer, capacity * (int)sizeof(int32_t));
 return n < 0 ? -1 : n / (int)sizeof(int32_t);
}
int ms_process(int32_t pid, MSProcess *r) {
 memset(r, 0, sizeof(*r)); struct proc_bsdinfo b = {0};
 if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b)) return 0;
 r->pid=pid; r->ppid=b.pbi_ppid; r->pgid=b.pbi_pgid; r->uid=b.pbi_uid;
 r->start_sec=b.pbi_start_tvsec; r->start_usec=b.pbi_start_tvusec;
 strlcpy(r->name, b.pbi_name[0] ? b.pbi_name : b.pbi_comm, sizeof(r->name));
 proc_pidpath(pid, r->path, sizeof(r->path));
 struct rusage_info_v2 u = {0};
 if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&u)==0) {
   r->footprint=u.ri_phys_footprint; r->rss=u.ri_resident_size; r->memory_valid=1;
 }
 // Recheck identity after the multi-call sample to reject a PID reused in between.
 struct proc_bsdinfo after = {0};
 if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after) ||
     b.pbi_start_tvsec!=after.pbi_start_tvsec || b.pbi_start_tvusec!=after.pbi_start_tvusec) return 0;
 return 1;
}
void ms_system(MSSystem *r) {
 memset(r,0,sizeof(*r)); r->pressure=-1;
 size_t n=sizeof(r->total); sysctlbyname("hw.memsize", &r->total,&n,0,0);
 vm_statistics64_data_t v={0}; mach_msg_type_number_t count=HOST_VM_INFO64_COUNT;
 mach_port_t host=mach_host_self(); vm_size_t page=0;
 if (host_page_size(host,&page)==KERN_SUCCESS && host_statistics64(host,HOST_VM_INFO64,(host_info64_t)&v,&count)==KERN_SUCCESS) {
   r->compressed=(uint64_t)v.compressor_page_count*page;
   r->used=((uint64_t)v.active_count+v.wire_count+v.compressor_page_count)*page;
   if(r->used>r->total) r->used=r->total;
   r->available=r->total-r->used; r->vm_valid=r->total>0;
 }
 mach_port_deallocate(mach_task_self(),host);
 struct xsw_usage swap={0}; n=sizeof(swap);
 if(sysctlbyname("vm.swapusage",&swap,&n,0,0)==0){ r->swap_used=swap.xsu_used; r->swap_valid=1; }
 int level=0; n=sizeof(level);
 if(sysctlbyname("kern.memorystatus_vm_pressure_level",&level,&n,0,0)==0) {
   if(level==1) r->pressure=0; else if(level==2) r->pressure=1; else if(level==4) r->pressure=2;
 }
 struct statvfs fs={0}; const char *home=getenv("HOME");
 if(statvfs(home ? home : "/",&fs)==0){r->disk_free=(uint64_t)fs.f_bavail*fs.f_frsize;r->disk_valid=1;}
}
int ms_process_exists(int32_t pid) {
 if(pid<=0) return 0;
 if(kill(pid,0)==0 || errno==EPERM) return 1;
 return errno==ESRCH ? 0 : -1;
}
int ms_validate_target(int32_t pid, uint64_t sec, uint64_t usec, const char *path) {
 MSProcess p; if(!ms_process(pid,&p)) return ESRCH;
 if(p.start_sec!=sec || p.start_usec!=usec || strcmp(p.path,path)!=0) return ESTALE;
 if(pid<=1 || pid==getpid() || p.uid!=getuid() || !path[0]) return EPERM;
 const char *protected[]={"/System/","/usr/","/bin/","/sbin/","/Library/Apple/"};
 for(unsigned i=0;i<sizeof(protected)/sizeof(protected[0]);i++) if(strncmp(path,protected[i],strlen(protected[i]))==0) return EPERM;
 // Never terminate any ancestor of the watchdog, even if added as a custom watch.
 int32_t ancestor=getppid();
 if(ancestor<=0) return EPERM;
 for(int i=0;i<64 && ancestor>1;i++){
  if(pid==ancestor) return EPERM;
  MSProcess a;
  if(!ms_process(ancestor,&a) || a.ppid<=0 || a.ppid==ancestor) return EPERM;
  ancestor=a.ppid;
 }
 // A missing or excessively deep ancestry cannot establish that a target is safe.
 if(ancestor>1) return EPERM;
 return 0;
}
int ms_signal_checked(int32_t pid, uint64_t sec, uint64_t usec, const char *path, int sig) {
 if(sig!=SIGTERM && sig!=SIGKILL) return EINVAL;
 int result=ms_validate_target(pid,sec,usec,path);
 if(result!=0) return result;
 return kill(pid,sig)==0 ? 0 : errno;
}
