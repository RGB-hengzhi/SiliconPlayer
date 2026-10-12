#include <sys/wait.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
int main(void){printf("%zu %zu %zu %d %d %d %d\n",sizeof(siginfo_t),offsetof(siginfo_t,si_pid),offsetof(siginfo_t,si_status),P_PID,WEXITED,WNOHANG,WNOWAIT);return 0;}
