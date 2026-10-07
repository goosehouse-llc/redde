"""A QR code for the terminal, enough of the standard for a pairing link: byte mode, error
correction level L, versions 1 to 6 (up to 134 bytes). Hermes doesn't ship a QR library, and a
plugin can't ask for one.
"""

# Version -> (data codewords, error-correction codewords per block, blocks), level L.
_VERSIONS = {1: (19, 7, 1), 2: (34, 10, 1), 3: (55, 15, 1), 4: (80, 20, 1), 5: (108, 26, 1), 6: (136, 18, 2)}

_EXP, _LOG = [0] * 512, [0] * 256
_x = 1
for _i in range(255):
    _EXP[_i], _LOG[_x] = _x, _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]


def _multiply(a, b):
    return 0 if a == 0 or b == 0 else _EXP[_LOG[a] + _LOG[b]]


def _error_correction(data, count):
    """Reed-Solomon remainder of `data` for `count` check codewords."""
    generator = [1]
    for i in range(count):
        generator = _times(generator, [1, _EXP[i]])
    remainder = [0] * count
    for byte in data:
        factor = byte ^ remainder[0]
        remainder = remainder[1:] + [0]
        for j in range(count):
            remainder[j] ^= _multiply(generator[j + 1], factor)
    return remainder


def _times(p, q):
    product = [0] * (len(p) + len(q) - 1)
    for i, a in enumerate(p):
        for j, b in enumerate(q):
            product[i + j] ^= _multiply(a, b)
    return product


def capacity(version=6):
    """Bytes a code of this version holds."""
    return _VERSIONS[version][0] - 2


def _codewords(data, version):
    total, check, blocks = _VERSIONS[version]
    bits = [0, 1, 0, 0] + [(len(data) >> i) & 1 for i in range(7, -1, -1)]
    for byte in data:
        bits += [(byte >> i) & 1 for i in range(7, -1, -1)]
    bits += [0] * min(4, total * 8 - len(bits))
    bits += [0] * (-len(bits) % 8)
    words = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    words += [(0xEC, 0x11)[i % 2] for i in range(total - len(words))]
    size = total // blocks
    parts = [words[i * size:(i + 1) * size] for i in range(blocks)]
    checks = [_error_correction(part, check) for part in parts]
    return [part[i] for i in range(size) for part in parts] + [c[i] for i in range(check) for c in checks]


def matrix(data):
    """The code for `data` (bytes) as rows of booleans, True for a dark module."""
    version = next((v for v in sorted(_VERSIONS) if len(data) <= capacity(v)), None)
    if version is None:
        raise ValueError("too long for a QR code this module can draw")
    size = 17 + 4 * version
    dark = [[False] * size for _ in range(size)]
    fixed = [[False] * size for _ in range(size)]

    def put(x, y, value):
        if 0 <= x < size and 0 <= y < size:
            dark[y][x], fixed[y][x] = value, True

    for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):          # finders and their separators
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                put(cx + dx, cy + dy, max(abs(dx), abs(dy)) in (0, 1, 3))
    for i in range(8, size - 8):                                     # timing
        put(i, 6, i % 2 == 0)
        put(6, i, i % 2 == 0)
    if version > 1:                                                  # one alignment pattern
        centre = 4 * version + 10
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                put(centre + dx, centre + dy, max(abs(dx), abs(dy)) != 1)
    for i in range(9):                                               # room for the format bits
        if i != 6:                                                   # (6 is the timing line)
            put(8, i, False), put(i, 8, False)
    for i in range(8):
        put(size - 1 - i, 8, False), put(8, size - 1 - i, False)
    put(8, size - 8, True)

    words, index = _codewords(data, version), 0
    right = size - 1
    while right > 0:                                                 # the zigzag, two columns at a time
        if right == 6:
            right -= 1
        for step in range(size):
            for x in (right, right - 1):
                y = size - 1 - step if (right + 1) & 2 == 0 else step
                if not fixed[y][x]:
                    if index < len(words) * 8:
                        dark[y][x] = bool(words[index >> 3] >> (7 - (index & 7)) & 1)
                    index += 1
        right -= 2

    masks = [lambda x, y: (x + y) % 2 == 0, lambda x, y: y % 2 == 0, lambda x, y: x % 3 == 0,
             lambda x, y: (x + y) % 3 == 0, lambda x, y: (x // 3 + y // 2) % 2 == 0,
             lambda x, y: x * y % 2 + x * y % 3 == 0, lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
             lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0]

    def finished(mask):
        grid = [[dark[y][x] != (masks[mask](x, y) and not fixed[y][x]) for x in range(size)] for y in range(size)]
        value = 1 << 3 | mask                                        # level L, then the mask
        remainder = value
        for _ in range(10):
            remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537)
        bits = (value << 10 | remainder) ^ 0x5412
        bit = lambda i: bool(bits >> i & 1)
        for i in range(6):
            grid[i][8] = bit(i)
        grid[7][8], grid[8][8], grid[8][7] = bit(6), bit(7), bit(8)
        for i in range(9, 15):
            grid[8][14 - i] = bit(i)
        for i in range(8):
            grid[8][size - 1 - i] = bit(i)
        for i in range(8, 15):
            grid[size - 15 + i][8] = bit(i)
        grid[size - 8][8] = True
        return grid

    def penalty(grid):
        score = 0
        lines = grid + [list(column) for column in zip(*grid)]
        for line in lines:                                           # long runs, and finder look-alikes
            run = 1
            for i in range(1, size):
                run = run + 1 if line[i] == line[i - 1] else 1
                score += 3 if run == 5 else 1 if run > 5 else 0
            text = "".join("1" if m else "0" for m in line)
            score += 40 * (text.count("10111010000") + text.count("00001011101"))
        for y in range(size - 1):                                    # 2x2 blocks
            for x in range(size - 1):
                if grid[y][x] == grid[y][x + 1] == grid[y + 1][x] == grid[y + 1][x + 1]:
                    score += 3
        darkness = sum(map(sum, grid)) * 100 // (size * size)        # balance
        return score + 10 * (abs(darkness - 50) // 5)

    return min((finished(mask) for mask in range(8)), key=penalty)


def render(grid, margin=4):
    """The code as text: two rows of modules to a line, black on white whatever the terminal's
    colours, with the quiet margin a camera needs."""
    size = len(grid) + 2 * margin
    at = lambda x, y: 0 <= y - margin < len(grid) and 0 <= x - margin < len(grid) and grid[y - margin][x - margin]
    lines = []
    for y in range(0, size, 2):
        cells = ""
        for x in range(size):
            top, bottom = at(x, y), at(x, y + 1)
            cells += "█" if top and bottom else "▀" if top else "▄" if bottom else " "
        lines.append("\x1b[30;107m" + cells + "\x1b[0m")
    return "\n".join(lines)
