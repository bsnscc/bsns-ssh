#include <libssh2.h>
#include <libssh2_sftp.h>
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void require(int ok, const char *what) {
    if(!ok) { fprintf(stderr, "FAIL: %s\n", what); exit(1); }
}
int main(int argc, char **argv) {
    require(argc == 6, "port user public-key private-key temporary-directory");
    require(libssh2_init(0) == 0, "library init");
    printf("libssh2 %s\n", libssh2_version(0));
    require(strcmp(libssh2_version(0), "1.11.1") == 0, "updated library version");
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)atoi(argv[1]));
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    require(connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0, "loopback connection");
    LIBSSH2_SESSION *s = libssh2_session_init();
    libssh2_session_set_timeout(s, 10000);
    require(libssh2_session_handshake(s, fd) == 0, "SSH handshake");
    /* The harness creates a fresh loopback-only server and its host key. */
    require(libssh2_userauth_publickey_fromfile(s, argv[2], argv[3], argv[4], "") == 0, "public-key authentication");
    LIBSSH2_CHANNEL *c = libssh2_channel_open_session(s);
    require(c != NULL, "exec channel");
    require(libssh2_channel_exec(c, "printf native-transport-ok") == 0, "exec request");
    char buffer[4096] = {0};
    ssize_t n = libssh2_channel_read(c, buffer, sizeof(buffer)-1);
    require(n > 0 && strcmp(buffer, "native-transport-ok") == 0, "exec output");
    libssh2_channel_close(c);
    libssh2_channel_free(c);
    LIBSSH2_SFTP *sftp = libssh2_sftp_init(s);
    require(sftp != NULL, "SFTP init");
    char path[2048], link[2048], missing[2048];
    snprintf(path,sizeof(path),"%s/payload.txt",argv[5]);
    snprintf(link,sizeof(link),"%s/payload-link",argv[5]);
    snprintf(missing,sizeof(missing),"%s/not-present",argv[5]);
    LIBSSH2_SFTP_HANDLE *h = libssh2_sftp_open(sftp,path,LIBSSH2_FXF_WRITE|LIBSSH2_FXF_CREAT|LIBSSH2_FXF_TRUNC,0600);
    require(h != NULL, "SFTP create");
    require(libssh2_sftp_write(h,"roundtrip",9) == 9,"SFTP write");
    libssh2_sftp_close(h);
    h = libssh2_sftp_open(sftp,path,LIBSSH2_FXF_READ,0);
    require(h != NULL,"SFTP reopen");
    memset(buffer,0,sizeof(buffer));
    require(libssh2_sftp_read(h,buffer,sizeof(buffer)-1) == 9 && strcmp(buffer,"roundtrip") == 0,"SFTP read");
    libssh2_sftp_close(h);
    require(libssh2_sftp_symlink(sftp,path,link) == 0,"SFTP symlink STATUS success (request ID skipped)");
    memset(buffer,0,sizeof(buffer));
    require(libssh2_sftp_realpath(sftp,link,buffer,sizeof(buffer)-1) > 0,"SFTP realpath NAME response");
    require(libssh2_sftp_readlink(sftp,missing,buffer,sizeof(buffer)-1) < 0,"SFTP missing symlink fails");
    require(libssh2_sftp_last_error(sftp) == LIBSSH2_FX_NO_SUCH_FILE,"SFTP STATUS reports code, not request ID");
    libssh2_sftp_unlink(sftp,link);
    libssh2_sftp_unlink(sftp,path);
    libssh2_sftp_shutdown(sftp);
    libssh2_session_disconnect(s,"test complete");
    libssh2_session_free(s);
    close(fd);
    libssh2_exit();
    puts("PASS: SSH authentication, exec, SFTP roundtrip, symlink, realpath and error status");
    return 0;
}
