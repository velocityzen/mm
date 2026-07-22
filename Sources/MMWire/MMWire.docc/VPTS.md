# VPTS — Variable-Precision Timestamp

The binary codec behind the wire time kinds: a bitmask-headed, variable-precision, bytewise-sortable calendar value.

> Note: This article is the normative VPTS specification. The wire protocol (<doc:WireProtocol>, section 8.3) constrains which VPTS shapes each schema kind admits; `MMVPTS` in MMSchema is the reference implementation.

**Version:** 0.2-draft
**Status:** Draft

## 1. Overview

VPTS is a compact binary encoding of Gregorian date-time values with explicit, variable precision. Like ISO 8601 reduced representations, a value may stop at any granularity (year, year-month, date, …, sub-second), but presence is declared by a bitmask header rather than by string length. All multi-byte fields are big-endian.

Design goals, in order:

1. Precision is explicit and part of the value (a "2026-07" is not a "2026-07-01").
2. Coarse values cost few bytes; a full nanosecond timestamp with offset costs 15 bytes.
3. Trivial validation (mask checks only).
4. Bytewise sort order equals chronological order for values of equal header.
5. Extensible: the header grows one byte at a time via a continuation bit.

VPTS encodes wall-clock calendar values. It is not a replacement for monotonic or epoch-based instants; use it where calendar semantics or declared precision matter.

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

Header `0x00` encodes the **null timestamp** (total size: 1 byte). Schemas that require a value MUST reject it.

### 2.2 Extension header byte

Present iff EXT is set. MUST NOT be `0x00` (an empty extension is non-canonical and invalid).

| Bit | Name   | Meaning |
|-----|--------|---------|
| 0   | OFFSET | offset field present |
| 1   | WIDE   | year is 8 bytes; fraction (if present) is 8 bytes |
| 2–7 | —      | reserved, MUST be 0 |

Bit 7 of the extension byte is reserved for a further continuation byte in future versions and MUST be 0 in v0.2.

### 2.3 Fields

Present fields are concatenated in this order: year, month, day, hour, minute, second, fraction, offset. No padding, no alignment.

| Field    | Narrow type | Wide type (WIDE set) | Range / meaning |
|----------|-------------|----------------------|------------------|
| year     | uint16 BE (2) | uint64 BE (8) | Biased: wire value = proleptic Gregorian year + 2¹⁵ (narrow) or + 2⁶³ (wide). Narrow covers −32768…32767; wide covers the full int64 range. |
| month    | uint8 (1)   | —                    | 1–12 |
| day      | uint8 (1)   | —                    | 1–31; must be valid for the given year/month |
| hour     | uint8 (1)   | —                    | 0–23 |
| minute   | uint8 (1)   | —                    | 0–59 |
| second   | uint8 (1)   | —                    | 0–60 (60 only for a positive leap second) |
| fraction | uint32 BE (4) | uint64 BE (8)      | Narrow: nanoseconds, 0–999 999 999. Wide: attoseconds (10⁻¹⁸ s), 0–999 999 999 999 999 999. |
| offset   | int16 BE (2) | —                    | Minutes east of UTC, −1439…+1439 |

Attoseconds are exactly 18 decimal digits, so the lossless ISO 8601 fraction mapping (§8) is preserved in wide mode; 1 ns = 10⁹ as, so narrow→wide conversion is exact.

WIDE applies to both the year field and (if present) the fraction field. A narrow year cannot be combined with a wide fraction, or vice versa.

## 3. Validity rules

A decoder MUST reject an encoding unless all of the following hold. Let `b1` be the header, `b2` the extension byte (0 if absent), `m = b1 & 0x3F`:

1. **Contiguity.** `(m & (m + 1)) == 0`. Valid `m`: `0x00, 0x01, 0x03, 0x07, 0x0F, 0x1F, 0x3F`.
2. **FRACTION requires SECOND** (b1 bit 6 ⇒ b1 bit 5).
3. **EXT canonicality.** If EXT is set, `b2 != 0x00` and `b2 & 0xFC == 0`.
4. **OFFSET requires HOUR** (b2 bit 0 ⇒ b1 bit 3). Offsets attach to times, as in ISO 8601.
5. **WIDE requires a year** (b2 bit 1 ⇒ `m != 0`).
6. Every present field is within its range, including calendar validity of `day` and the fraction upper bounds.
7. The input contains exactly the number of bytes implied by the header(s). Field lengths are fully determined by `b1`/`b2`, so VPTS is self-delimiting inside any framing.

## 4. Semantics

**Precision.** Absent trailing fields mean *unspecified*, not zero. `2026-07` denotes the month, not its first instant. Two values with different headers are never equal; range or containment comparisons across precisions are application-defined.

**Fraction.** Presence of FRACTION declares sub-second precision even when the value is 0 (`12:00:00.000000000` ≠ `12:00:00`). Encoders MUST NOT add FRACTION merely because a zero is available, and MUST NOT use WIDE when the value fits the narrow forms — encode the precision and range the source data actually has.

**Offset.** When present, the encoded fields are local wall-clock time and `UTC = local − offset`, matching ISO 8601. When absent, interpretation is context/local time; a protocol embedding VPTS SHOULD declare a default (UTC is RECOMMENDED). Offset `0` means UTC ("Z").

**Leap second.** `second = 60` is permitted only when a positive leap second actually occurred at that instant; decoders MAY accept it without verifying.

## 5. Ordering

For two encodings with the **same header and extension byte** and no OFFSET bit, unsigned lexicographic comparison of the full byte sequence equals chronological comparison. This follows from big-endian fields, most-significant-first field order, and the year bias (which holds in both narrow and wide forms).

Values with offsets or differing headers MUST be compared after decoding.

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

Size formula: `1 + [EXT] + Y·[m≠0] + popcount(m>>1) + F·[FRACTION] + 2·[OFFSET]`, where `Y = 8` if WIDE else `2`, and `F = 8` if WIDE else `4`.

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

Workings: year 2026 + 2¹⁵ = 34794 = `0x87EA`; year 2026 + 2⁶³ = `0x80000000000007EA`; 2⁶³ − 13 800 000 000 = `0x7FFFFFFCC974B600`; fraction 123 456 789 ns = `0x075BCD15`; offset −240 min = `0xFF10`.

Invalid examples a decoder MUST reject:

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

Every valid VPTS value maps to exactly one ISO 8601 reduced representation and back, with these caveats: years outside 0000–9999 require ISO's expanded-year form (mutual agreement in ISO; native in VPTS); decimal fractions longer than 9 digits (narrow) or 18 digits (wide) are unrepresentable; and ISO ordinal/week dates have no VPTS form — convert to calendar dates first.

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

- Header bit 7 repurposed from OFFSET to EXT (continuation).
- OFFSET moved to extension bit 0; offset-bearing values grow by 1 byte.
- WIDE added (extension bit 1): 64-bit biased year, 64-bit attosecond fraction.
- Extension byte bit 7 reserved as a further continuation bit.
