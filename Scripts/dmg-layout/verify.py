"""Read the generated Finder database independently, using Python's stdlib."""
import pathlib
import plistlib
import struct
import sys

root, alias_output = map(pathlib.Path, sys.argv[1:])
assert (root / "Applications").is_symlink()
assert (root / "Applications").readlink() == pathlib.Path("/Applications")
with (root / "YUANNotch.app/Contents/Info.plist").open("rb") as file:
    assert plistlib.load(file)["CFBundleIdentifier"] == "io.github.hy0iu.YUANNotch"

data = (root / ".DS_Store").read_bytes()
def integer(offset):
    return struct.unpack_from(">I", data, offset)[0]

assert integer(0) == 1 and data[4:8] == b"Bud1"
assert integer(8) == integer(16)
allocator = integer(8) + 4
count = integer(allocator)
addresses = [integer(allocator + 8 + index * 4) for index in range(count)]
def block(index):
    address = addresses[index]
    offset, size = (address & ~31) + 4, 1 << (address & 31)
    assert 4 <= offset and offset + size <= len(data)
    return offset, size

directory = allocator + 8 + ((count + 255) // 256) * 1024
assert integer(directory) == 1 and data[directory + 4:directory + 9] == b"\x04DSDB"
tree, _ = block(integer(directory + 9))
leaf, size = block(integer(tree))
assert integer(tree + 4) == 0 and integer(tree + 12) == 1
assert integer(tree + 16) == 4096 and integer(leaf) == 0
record_count = integer(leaf + 4)
assert record_count == integer(tree + 8)
cursor = leaf + 8
records = {}
for _ in range(record_count):
    length = integer(cursor)
    cursor += 4
    name = data[cursor:cursor + length * 2].decode("utf-16-be")
    cursor += length * 2
    code, kind = data[cursor:cursor + 4], data[cursor + 4:cursor + 8]
    cursor += 8
    if kind == b"blob":
        length = integer(cursor)
        cursor += 4
    else:
        assert kind == b"type"
        length = 4
    records[name, code] = data[cursor:cursor + length]
    cursor += length
    assert cursor <= leaf + size

window = plistlib.loads(records[".", b"bwsp"])
icons = plistlib.loads(records[".", b"icvp"])
assert window["WindowBounds"] == "{{180, 140}, {640, 400}}"
assert not any(window[key] for key in ("ShowSidebar", "ShowToolbar", "ShowStatusBar", "ShowPathbar"))
assert records[".", b"vstl"] == b"icnv"
assert icons["arrangeBy"] == "none" and icons["iconSize"] == 80
assert icons["backgroundType"] == 2
for name, point in (("YUANNotch.app", (170, 205)), ("Applications", (470, 205))):
    assert struct.unpack_from(">II", records[name, b"Iloc"]) == point
    assert 40 <= point[0] <= 600 and 40 <= point[1] <= 360

alias_output.write_bytes(icons["backgroundImageAlias"])
assert (root / ".background/installer.png").read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
print("PASS Finder layout, icon positions, image background, and Applications link")
