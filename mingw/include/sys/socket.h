#ifndef SOCKET_H_INCLUDED
#define SOCKET_H_INCLUDED

#include <winsock2.h>
#include <ws2tcpip.h>

typedef unsigned short in_port_t;

/* Structure describing messages sent by
   `sendmsg' and received by `recvmsg'.  */
struct msghdr {
    void *msg_name;		/* Address to send to/receive from.  */
    socklen_t msg_namelen;	/* Length of address data.  */
    struct iovec *msg_iov;	/* Vector of data to send/receive into.  */
    size_t msg_iovlen;		/* Number of elements in the vector.  */
};

int sock_startup(void);
int sock_cleanup(void);
ssize_t sendmsg(int socket, const struct msghdr *message, int flags);
ssize_t sock_write(int fd, const void *buf, size_t count);
ssize_t sock_read(int fd, void *buf, size_t nbyte);
int sock_close(int fd);
int conv_wsaerr_to_errno(int wsa_err);

#endif // SOCKET_H_INCLUDED

