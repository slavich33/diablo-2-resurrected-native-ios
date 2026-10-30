#include "OnlineTransport.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <poll.h>
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char request[]="native-c-client-fixture";
static const char response[]="native-c-peer-fixture";
static int listener, peer_ok;
static void *serve(void *unused) {
 (void)unused; struct pollfd event={listener,POLLIN,0};
 if(poll(&event,1,3000)<=0) return NULL;
 int peer=accept(listener,NULL,NULL); if(peer<0)return NULL;
 struct timeval timeout={3,0}; setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
 char bytes[sizeof(request)]; size_t received=0;
 while(received<sizeof(request)-1) { ssize_t n=recv(peer,bytes+received,sizeof(request)-1-received,0); if(n<=0)goto done; received+=(size_t)n; }
 if(memcmp(bytes,request,sizeof(request)-1))goto done;
 for(size_t i=0;i<sizeof(response)-1;i++) if(send(peer,response+i,1,0)!=1)goto done;
 peer_ok=1;
 done: shutdown(peer,SHUT_WR); close(peer);return NULL;
}
int main(void) {
 listener=socket(AF_INET,SOCK_STREAM,0); if(listener<0)return 2;
 struct sockaddr_in address={0}; address.sin_len=sizeof(address);address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
 if(bind(listener,(struct sockaddr *)&address,sizeof(address))||listen(listener,1))return 3;
 socklen_t size=sizeof(address);if(getsockname(listener,(struct sockaddr *)&address,&size))return 4;
 pthread_t thread;if(pthread_create(&thread,NULL,serve,NULL))return 5;
 void *stream=dm_online_tcp_open("127.0.0.1",ntohs(address.sin_port),2000);if(!stream)return 6;
 for(int i=0;i<3000&&dm_online_tcp_state(stream)==1;i++)usleep(1000);
 if(dm_online_tcp_state(stream)!=2)return 7;
 if(dm_online_tcp_send(stream,request,sizeof(request)-1))return 8;
 char bytes[sizeof(response)]={0};size_t received=0;
 for(int i=0;i<3000&&received<sizeof(response)-1;i++) {
  int n=dm_online_tcp_read(stream,bytes+received,sizeof(response)-1-received);
  if(n>0)received+=(size_t)n;else if(n!=-1)break;
  usleep(1000);
 }
 dm_online_tcp_release(stream);pthread_join(thread,NULL);close(listener);
 if(received!=sizeof(response)-1||memcmp(bytes,response,sizeof(response)-1)||!peer_ok)return 9;
 puts("C ABI and native TCP round trip verified against an independent POSIX peer.");return 0;
}
