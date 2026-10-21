# VPTS: Variable-Precision Timestamp

The binary codec for the wire time kinds: a calendar value with a bitmask header and variable precision. Its bytes sort chronologically.

> Note: This article is the normative VPTS specification. The wire protocol (<doc:WireProtocol>, section 8.3) defines which VPTS shapes each schema kind accepts. `MMVPTS` in MMSchema is the reference implementation.

**Version:** 0.2-draft
**Status:** Draft

## 1. Overview

VPTS is a compact binary encoding of Gregorian date-time values with explicit, variable precision. As in ISO 8601 reduced representations, a value can stop at any granularity (year, year-month, date, and so on down to sub-second). A bitmask header, not string length, declares which fields are present. All multi-byte fields are big-endian.

Design goals, in priority order:

1. Precision is explicit and part of the value. "2026-07" is not "2026-07-01".
2. Coarse values use few bytes. A full nanosecond timestamp with offset uses 15 bytes.
3. Validation is simple: mask checks only.
4. For values with the same header, bytewise sort order equals chronological order.
5. The format is extensible. A continuation bit adds one header byte at a time.

VPTS encodes wall-clock calendar values. It does not replace monotonic or epoch-based instants. Use it when calendar semantics or declared precision matter.

## 2. Wire layout

```
+---------+-------------+-----------------------------+
| header  | ext header  |  fields (present bits only) |
| 1 byte  | 0–1 byte    |  0–23 bytes                 |
+---------+-------------+-----------------------------+
```

### 2.1 Header byte

| Bit | Name     | Meaning |
|-----|----------|---------|
| 0   | YEAR     | year field present |
| 1   | MONTH    | month field present |
| 2   | DAY      | day field present |
| 3   | HOUR     | hour field present |
| 4   | MINUTE   | minute field present |
| 5   | SECOND   | second field present |
| 6   | FRACTION | fraction field present |
| 7   | EXT      | extension header byte follows |

Header `0x00` encodes the **null timestamp**. Its total size is 1 byte. Schemas that require a value MUST reject it.

### 2.2 Extension header byte

Present if and only if EXT is set. It MUST NOT be `0x00`. An empty extension is non-canonical and invalid.

| Bit | Name   | Meaning |
|-----|--------|---------|
| 0   | OFFSET | offset field present |
| 1   | WIDE   | year is 8 bytes; fraction (if present) is 8 bytes |
| 2–7 | —      | reserved, MUST be 0 |

Bit 7 of the extension byte is reserved for a further continuation byte in future versions. It MUST be 0 in v0.2.

### 2.3 Fields

Present fields are concatenated in this order: year, month, day, hour, minute, second, fraction, offset. There is no padding and no alignment.

| Field    | Narrow type | Wide type (WIDE set) | Range / meaning |
|----------|-------------|----------------------|------------------|
| year     | uint16 BE (2) | uint64 BE (8) | Biased. Wire value = proleptic Gregorian year + 2¹⁵ (narrow) or + 2⁶³ (wide). Narrow covers −32768…32767. Wide covers the full int64 range. |
| month    | uint8 (1)   | —                    | 1 to 12 |
| day      | uint8 (1)   | —                    | 1 to 31. Must be valid for the given year and month. |
| hour     | uint8 (1)   | —                    | 0 to 23 |
| minute   | uint8 (1)   | —                    | 0 to 59 |
| second   | uint8 (1)   | —                    | 0 to 60 (60 only for a positive leap second) |
| fraction | uint32 BE (4) | uint64 BE (8)      | Narrow: nanoseconds, 0 to 999 999 999. Wide: attoseconds (10⁻¹⁸ s), 0 to 999 999 999 999 999 999. |
| offset   | int16 BE (2) | —                    | Minutes east of UTC, −1439…+1439 |

Attoseconds have exactly 18 decimal digits. Wide mode therefore keeps the lossless ISO 8601 fraction mapping (§8). 1 ns = 10⁹ as, so conversion from narrow to wide is exact.

WIDE applies to the year field and, if present, to the fraction field. A narrow year cannot be combined with a wide fraction, or the reverse.

## 3. Validity rules

A decoder MUST reject an encoding unless all of these rules hold. Let `b1` be the header, `b2` the extension byte (0 if absent), and `m = b1 & 0x3F`:

1. **Contiguity.** `(m & (m + 1)) == 0`. Valid `m` values: `0x00, 0x01, 0x03, 0x07, 0x0F, 0x1F, 0x3F`.
2. **FRACTION requires SECOND** (b1 bit 6 ⇒ b1 bit 5).
3. **EXT canonicality.** If EXT is set, `b2 != 0x00` and `b2 & 0xFC == 0`.
4. **OFFSET requires HOUR** (b2 bit 0 ⇒ b1 bit 3). Offsets belong to times, as in ISO 8601.
5. **WIDE requires a year** (b2 bit 1 ⇒ `m != 0`).
6. Every present field is within its range. This includes calendar validity of `day` and the fraction upper bounds.
7. The input contains exactly the number of bytes the header(s) imply. `b1` and `b2` fully determine the field lengths, so VPTS is self-delimiting inside any framing.

## 4. Semantics

**Precision.** An absent trailing field means *unspecified*, not zero. `2026-07` denotes the whole month, not its first instant. Two values with different headers are never equal. The application defines range or containment comparisons across precisions.

**Fraction.** If FRACTION is present, the value has sub-second precision, even when the fraction is 0 (`12:00:00.000000000` ≠ `12:00:00`). Encoders MUST NOT add FRACTION only because a zero is available. Encoders MUST NOT use WIDE when the value fits the narrow forms. Encode only the precision and range the source data actually has.

**Offset.** When the offset is present, the encoded fields are local wall-clock time and `UTC = local − offset`, as in ISO 8601. When the offset is absent, the value is context-defined or local time. A protocol that embeds VPTS SHOULD declare a default (UTC is RECOMMENDED). Offset `0` means UTC ("Z").

**Leap second.** `second = 60` is permitted only when a positive leap second actually occurred at that instant. Decoders MAY accept it without checking this.

## 5. Ordering

For two encodings with the **same header and extension byte** and no OFFSET bit, unsigned lexicographic comparison of the full byte sequence equals chronological comparison. This follows from big-endian fields, most-significant-first field order, and the year bias (in both narrow and wide forms).

Values with offsets or with different headers MUST be compared after decoding.

## 6. Sizes

| Content                          | Header(s)  | Total bytes | ISO 8601 (chars) |
|----------------------------------|------------|-------------|------------------|
| null                             | `00`       | 1           | —   |
| year                             | `01`       | 3           | 4   |
| year-month                       | `03`       | 4           | 7   |
| date                             | `07`       | 5           | 10  |
| date + hh:mm:ss                  | `3F`       | 8           | 19  |
| … + nanoseconds                  | `7F`       | 12          | 29  |
| date + hh:mm:ss, UTC             | `BF 01`    | 11          | 20  |
| … + nanoseconds + offset         | `FF 01`    | 15          | 35  |
| wide year only                   | `81 02`    | 10          | varies |
| … + attoseconds + offset (max)   | `FF 03`    | 25          | 44  |

Size formula: `1 + [EXT] + Y·[m≠0] + popcount(m>>1) + F·[FRACTION] + 2·[OFFSET]`, where `Y = 8` if WIDE, else `2`, and `F = 8` if WIDE, else `4`.

## 7. Test vectors

| Value | Bytes (hex) |
|---|---|
| null | `00` |
| `2026` | `01 87 EA` |
| `2026-07-22` | `07 87 EA 07 16` |
| `2026-07-22T14:30:00Z` | `BF 01 87 EA 07 16 0E 1E 00 00 00` |
| `2026-07-22T14:30:00.123456789-04:00` | `FF 01 87 EA 07 16 0E 1E 00 07 5B CD 15 FF 10` |
| year −13 800 000 000 (wide) | `81 02 7F FF FF FC C9 74 B6 00` |
| `2026-07-22T14:30:00.000000000000000001Z` | `FF 03 80 00 00 00 00 00 07 EA 07 16 0E 1E 00 00 00 00 00 00 00 00 01 00 00` |

Calculations:

- year 2026 + 2¹⁵ = 34794 = `0x87EA`
- year 2026 + 2⁶³ = `0x80000000000007EA`
- 2⁶³ − 13 800 000 000 = `0x7FFFFFFCC974B600`
- fraction 123 456 789 ns = `0x075BCD15`
- offset −240 min = `0xFF10`

A decoder MUST reject these invalid examples:

| Bytes | Reason |
|---|---|
| `05 87 EA 16` | non-contiguous mask (year+day, no month) |
| `41 87 EA` | FRACTION without SECOND |
| `81 00 87 EA` | EXT set but extension byte empty |
| `87 01 87 EA 07 16 00 00` | OFFSET without HOUR |
| `80 02` | WIDE with no year field |
| `81 04 87 EA` | reserved extension bit set |
| `07 87 EA 02 1E` | Feb 30 |

## 8. ISO 8601 mapping

Every valid VPTS value maps to exactly one ISO 8601 reduced representation and back, with these exceptions:

- Years outside 0000 to 9999 require the ISO expanded-year form. ISO allows this form only by mutual agreement. VPTS supports it natively.
- Decimal fractions longer than 9 digits (narrow) or 18 digits (wide) cannot be represented.
- ISO ordinal dates and week dates have no VPTS form. Convert them to calendar dates first.

## 9. Reference validation

```
valid(b1, b2) =                       // b2 = 0 when EXT clear
    let m = b1 & 0x3F
    (m & (m + 1)) == 0
    && (b1 & 0x40 == 0 || m & 0x20 != 0)      // FRACTION ⇒ SECOND
    && (b1 & 0x80 != 0) == (b2 != 0)          // EXT ⇔ non-empty ext byte
    && (b2 & 0xFC) == 0                       // reserved bits clear
    && (b2 & 0x01 == 0 || m & 0x08 != 0)      // OFFSET ⇒ HOUR
    && (b2 & 0x02 == 0 || m != 0)             // WIDE ⇒ YEAR
```

## 10. Changes from 0.1

- Header bit 7 changed from OFFSET to EXT (continuation).
- OFFSET moved to extension bit 0. Values with an offset are 1 byte larger.
- WIDE added (extension bit 1): 64-bit biased year, 64-bit attosecond fraction.
- Extension byte bit 7 reserved as a further continuation bit.
