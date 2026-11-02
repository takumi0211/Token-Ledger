#ifndef TOKEN_LEDGER_ARCHIVE_READER_H
#define TOKEN_LEDGER_ARCHIVE_READER_H

#include <stddef.h>
#include <sys/types.h>
typedef struct LedgerArchiveReader LedgerArchiveReader;
LedgerArchiveReader *ledger_archive_open(const char *path, const char *library);
LedgerArchiveReader *ledger_plain_open(const char *path);
/* Returns one physical line, including its newline. 0 = EOF, -1 = corruption/error. */
ssize_t ledger_archive_next(LedgerArchiveReader *reader, const unsigned char **line);
void ledger_archive_close(LedgerArchiveReader *reader);

#endif
