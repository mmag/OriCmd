// Declarations for the subset of the system libarchive (/usr/lib/libarchive.2.dylib)
// used by OriCmd. The macOS SDK ships the library but not its headers; these
// prototypes follow libarchive 3.x's archive.h and archive_entry.h.
#ifndef ORICMD_LIBARCHIVE_SHIM_H
#define ORICMD_LIBARCHIVE_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <time.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_RETRY (-10)
#define ARCHIVE_WARN (-20)
#define ARCHIVE_FAILED (-25)
#define ARCHIVE_FATAL (-30)

#define ARCHIVE_EXTRACT_PERM (0x0002)
#define ARCHIVE_EXTRACT_TIME (0x0004)
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS (0x0100)
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT (0x0200)

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_block(struct archive *, const void **buffer, size_t *size, int64_t *offset);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
/// ARCHIVE_FORMAT_* of the archive being read (zip: 0x50000 and its variants).
int archive_format(struct archive *);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
const char *archive_entry_hardlink(struct archive_entry *);
void archive_entry_set_hardlink(struct archive_entry *, const char *);
int64_t archive_entry_size(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int flags);
int archive_write_disk_set_standard_lookup(struct archive *);
int archive_write_header(struct archive *, struct archive_entry *);
int archive_write_data_block(struct archive *, const void *, size_t, int64_t offset);
int archive_write_finish_entry(struct archive *);
int archive_write_free(struct archive *);

struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_options(struct archive *, const char *options);
int archive_write_set_passphrase(struct archive *, const char *);
int archive_write_open_filename(struct archive *, const char *filename);
ssize_t archive_write_data(struct archive *, const void *, size_t);
int archive_write_close(struct archive *);
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
void archive_entry_copy_stat(struct archive_entry *, const struct stat *);
void archive_entry_set_symlink(struct archive_entry *, const char *);

#endif
