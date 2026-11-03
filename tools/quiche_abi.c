#include <stddef.h>
#include <stdio.h>
#include <quiche.h>

int main(void) {
    printf("{\"sockaddr\":%zu,\"sockaddr_storage\":%zu,\"timespec\":%zu,"
           "\"recv_info\":%zu,\"send_info\":%zu,\"h3_header\":%zu,"
           "\"h3_event_type\":%zu,\"shutdown\":%zu,"
           "\"recv_to_offset\":%zu,\"send_to_offset\":%zu}\n",
           sizeof(struct sockaddr), sizeof(struct sockaddr_storage), sizeof(struct timespec),
           sizeof(quiche_recv_info), sizeof(quiche_send_info), sizeof(quiche_h3_header),
           sizeof(enum quiche_h3_event_type), sizeof(enum quiche_shutdown),
           offsetof(quiche_recv_info, to), offsetof(quiche_send_info, to));
    return 0;
}
