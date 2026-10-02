"""Reads the stored RAR 4 archives mkrar4.py writes, for the fake lsar and unar."""
import struct, time


def entries(path):
    data = open(path, "rb").read()
    position, index, found = 7, 0, []
    while position + 7 <= len(data):
        _, kind, flags, size = struct.unpack_from("<HBHH", data, position)
        if kind == 0x74:
            packed, unpacked, _, _, ftime, _, _, name_size, attributes = struct.unpack_from(
                "<IIBIIBBHI", data, position + 7)
            name = data[position + 32:position + 32 + name_size].decode()
            stamp = time.mktime(((ftime >> 25) + 1980, ftime >> 21 & 15, ftime >> 16 & 31,
                                 ftime >> 11 & 31, ftime >> 5 & 63, (ftime & 31) * 2, 0, 0, -1))
            found.append({"index": index, "name": name, "size": unpacked, "time": stamp, "mode": attributes & 0o7777,
                          "data": data[position + size:position + size + packed]})
            index += 1
            position += size + packed
        else:
            position += size
    return found
