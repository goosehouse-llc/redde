"""QR codes for the bridge's setup link, in plain Python, so a terminal shows one with nothing to
install (`qrencode` was needed before). Byte mode, error correction level M, the smallest version
that holds the text. Follows ISO/IEC 18004 the way Project Nayuki's reference encoder lays it out.

    print(redde_qr.terminal("https://example.com"))
"""
from __future__ import annotations

# Level M, by version (index 0 unused).
_ECC_PER_BLOCK = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
                  26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28]
_BLOCKS = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
           17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49]
_FORMAT_M = 0


def _raw_modules(version: int) -> int:
    result = (16 * version + 128) * version + 64
    if version >= 2:
        aligns = version // 7 + 2
        result -= (25 * aligns - 10) * aligns - 55
        if version >= 7:
            result -= 36
    return result


def _data_codewords(version: int) -> int:
    return _raw_modules(version) // 8 - _ECC_PER_BLOCK[version] * _BLOCKS[version]


def _gf_mul(x: int, y: int) -> int:
    z = 0
    for i in reversed(range(8)):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def _rs_divisor(degree: int) -> list:
    result = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            result[j] = _gf_mul(result[j], root)
            if j + 1 < degree:
                result[j] ^= result[j + 1]
        root = _gf_mul(root, 0x02)
    return result


def _rs_remainder(data: list, divisor: list) -> list:
    result = [0] * len(divisor)
    for b in data:
        factor = b ^ result.pop(0)
        result.append(0)
        for i, coef in enumerate(divisor):
            result[i] ^= _gf_mul(coef, factor)
    return result


def _codewords(text: bytes, version: int) -> list:
    capacity = _data_codewords(version)
    bits: list = []

    def put(value: int, length: int) -> None:
        bits.extend((value >> i) & 1 for i in reversed(range(length)))

    put(0b0100, 4)
    put(len(text), 8 if version <= 9 else 16)
    for b in text:
        put(b, 8)
    put(0, min(4, capacity * 8 - len(bits)))
    put(0, -len(bits) % 8)
    data = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0xEC
    while len(data) < capacity:
        data.append(pad)
        pad ^= 0xEC ^ 0x11
    # Split into blocks, add each block's error correction, interleave.
    blocks_n, ecc_n = _BLOCKS[version], _ECC_PER_BLOCK[version]
    raw = _raw_modules(version) // 8
    short_n = blocks_n - raw % blocks_n
    short_len = raw // blocks_n
    divisor = _rs_divisor(ecc_n)
    blocks, k = [], 0
    for i in range(blocks_n):
        take = short_len - ecc_n + (0 if i < short_n else 1)
        block = data[k:k + take]
        k += take
        ecc = _rs_remainder(block, divisor)
        if i < short_n:
            block.append(0)
        blocks.append(block + ecc)
    out = []
    for i in range(len(blocks[0])):
        for j, block in enumerate(blocks):
            if i != short_len - ecc_n or j >= short_n:
                out.append(block[i])
    return out


def _alignment_positions(version: int, size: int) -> list:
    if version == 1:
        return []
    aligns = version // 7 + 2
    step = 26 if version == 32 else (version * 4 + aligns * 2 + 1) // (aligns * 2 - 2) * 2
    return [6] + sorted(size - 7 - i * step for i in range(aligns - 1))


class _Matrix:
    def __init__(self, version: int):
        self.version = version
        self.size = version * 4 + 17
        self.dark = [[False] * self.size for _ in range(self.size)]
        self.fixed = [[False] * self.size for _ in range(self.size)]

    def set(self, x: int, y: int, dark: bool) -> None:
        self.dark[y][x] = dark
        self.fixed[y][x] = True

    def functions(self) -> None:
        n = self.size
        for i in range(n):
            self.set(6, i, i % 2 == 0)
            self.set(i, 6, i % 2 == 0)
        for cx, cy in ((3, 3), (n - 4, 3), (3, n - 4)):
            for dy in range(-4, 5):
                for dx in range(-4, 5):
                    x, y = cx + dx, cy + dy
                    if 0 <= x < n and 0 <= y < n:
                        self.set(x, y, max(abs(dx), abs(dy)) not in (2, 4))
        spots = _alignment_positions(self.version, n)
        last = len(spots) - 1
        for i, cx in enumerate(spots):
            for j, cy in enumerate(spots):
                if (i, j) in ((0, 0), (0, last), (last, 0)):
                    continue
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        self.set(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)
        self.format(0)
        if self.version >= 7:
            rem = self.version
            for _ in range(12):
                rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
            bits = self.version << 12 | rem
            for i in range(18):
                bit = (bits >> i) & 1 == 1
                a, b = n - 11 + i % 3, i // 3
                self.set(a, b, bit)
                self.set(b, a, bit)

    def format(self, mask: int) -> None:
        data = _FORMAT_M << 3 | mask
        rem = data
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        bits = (data << 10 | rem) ^ 0x5412

        def bit(i: int) -> bool:
            return (bits >> i) & 1 == 1

        n = self.size
        for i in range(6):
            self.set(8, i, bit(i))
        self.set(8, 7, bit(6))
        self.set(8, 8, bit(7))
        self.set(7, 8, bit(8))
        for i in range(9, 15):
            self.set(14 - i, 8, bit(i))
        for i in range(8):
            self.set(n - 1 - i, 8, bit(i))
        for i in range(8, 15):
            self.set(8, n - 15 + i, bit(i))
        self.set(8, n - 8, True)

    def place(self, codewords: list) -> None:
        n, i, total = self.size, 0, len(codewords) * 8
        right = n - 1
        while right >= 1:
            if right == 6:
                right = 5
            for vert in range(n):
                for j in range(2):
                    x = right - j
                    upward = ((right + 1) & 2) == 0
                    y = n - 1 - vert if upward else vert
                    if not self.fixed[y][x] and i < total:
                        self.dark[y][x] = (codewords[i >> 3] >> (7 - (i & 7))) & 1 == 1
                        i += 1
            right -= 2

    def masked(self, mask: int) -> list:
        rule = [lambda x, y: (x + y) % 2 == 0, lambda x, y: y % 2 == 0, lambda x, y: x % 3 == 0,
                lambda x, y: (x + y) % 3 == 0, lambda x, y: (x // 3 + y // 2) % 2 == 0,
                lambda x, y: x * y % 2 + x * y % 3 == 0, lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
                lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0][mask]
        return [[self.dark[y][x] ^ (not self.fixed[y][x] and rule(x, y)) for x in range(self.size)]
                for y in range(self.size)]


def _penalty(grid: list) -> int:
    """The standard's penalty, less its finder-lookalike rule: runs, 2×2 blocks, balance."""
    n, score = len(grid), 0
    for lines in (grid, [list(col) for col in zip(*grid)]):
        for line in lines:
            run = 1
            for a, b in zip(line, line[1:]):
                if a == b:
                    run += 1
                else:
                    score += run - 2 if run >= 5 else 0
                    run = 1
            score += run - 2 if run >= 5 else 0
    for y in range(n - 1):
        for x in range(n - 1):
            if grid[y][x] == grid[y][x + 1] == grid[y + 1][x] == grid[y + 1][x + 1]:
                score += 3
    dark = sum(map(sum, grid))
    score += abs(dark * 20 - n * n * 10) // (n * n) * 10
    return score


def matrix(text: str) -> list:
    """The QR code's modules, rows of booleans (True is dark), without the quiet zone."""
    data = text.encode("utf-8")
    version = next((v for v in range(1, 41)
                    if 4 + (8 if v <= 9 else 16) + 8 * len(data) <= _data_codewords(v) * 8), None)
    if version is None:
        raise ValueError("too long for a QR code")
    m = _Matrix(version)
    m.functions()
    m.place(_codewords(data, version))
    best = None
    for mask in range(8):
        m.format(mask)
        grid = m.masked(mask)
        score = _penalty(grid)
        if best is None or score < best[0]:
            best = (score, grid)
    return best[1]


def terminal(text: str, quiet: int = 2) -> str:
    """The code in half blocks, two rows to a line, black on white whatever the terminal's colours."""
    grid = matrix(text)
    n = len(grid) + 2 * quiet

    def dark(x: int, y: int) -> bool:
        x, y = x - quiet, y - quiet
        return 0 <= y < len(grid) and 0 <= x < len(grid) and grid[y][x]

    lines = []
    for y in range(0, n, 2):
        cells = []
        for x in range(n):
            top = 16 if dark(x, y) else 231
            bottom = 16 if dark(x, y + 1) else 231
            cells.append(f"\x1b[38;5;{top};48;5;{bottom}m▀")
        lines.append("".join(cells) + "\x1b[0m")
    return "\n".join(lines)
