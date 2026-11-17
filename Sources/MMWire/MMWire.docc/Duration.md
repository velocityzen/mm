# Duration: the binary form of elapsed time

The binary codec for the wire's `duration` kind: a signed span of time, exact to the attosecond, in 1 to 18 bytes.

> Note: This article is the normative duration specification. The wire protocol (<doc:WireProtocol>, section 8.3) assigns the kind its tag. `MMDuration` in MMSchema is the reference implementation.

## 1. Overview

A duration is an exact amount of elapsed time: a sign, whole seconds, and a fraction of a second. It is not a calendar quantity, so it has no years, months or weeks, whose lengths vary.

The range is that of Swift's `Duration`: from −2¹²⁷ to 2¹²⁷ − 1 attoseconds, about ±5.4 × 10¹² years. A value outside it is not a duration.

Design goals, in priority order:

1. Every value has exactly one encoding, so equal values have equal bytes.
2. Common values are short: a whole number of seconds under 256 takes 2 bytes, and a millisecond timeout 3 to 5.
3. The encoding delimits itself: the header byte gives the length of everything after it.

## 2. Wire layout

```
+---------+--------------------+------------------+
| header  | seconds            | fraction         |
| 1 byte  | 0–9 bytes          | 0, 2, 3, 4 or 8  |
+---------+--------------------+------------------+
```

### 2.1 Header byte

| Bits | Name     | Meaning |
|------|----------|---------|
| 0–3  | LENGTH   | the number of seconds bytes, 0 to 9 |
| 4–6  | UNIT     | the fraction's unit (table below) |
| 7    | NEGATIVE | set for a span below zero |

| UNIT | Fraction | Width | One second is |
|------|----------|-------|---------------|
| 0 | none | 0 bytes | — |
| 1 | milliseconds | 2 bytes | 1,000 |
| 2 | microseconds | 3 bytes | 10⁶ |
| 3 | nanoseconds | 4 bytes | 10⁹ |
| 4 | attoseconds | 8 bytes | 10¹⁸ |

LENGTH values 10 to 15 and UNIT values 5 to 7 are reserved and invalid.

### 2.2 Fields

- **seconds**: the whole seconds of the span's size, an unsigned big-endian integer of LENGTH bytes. LENGTH 0 means zero seconds.
- **fraction**: the rest of the size below one second, as a count of UNIT, an unsigned big-endian integer of the unit's width. It is less than one second in that unit.

The value is the size, seconds × 10¹⁸ + count × (attoseconds per unit), negated when NEGATIVE is set.

## 3. Canonical form

An encoder MUST write the one canonical encoding, and a decoder MUST refuse every other:

1. The seconds have no leading zero byte. Zero seconds is LENGTH 0.
2. A fraction of zero is no fraction: UNIT 0.
3. A fraction is written in the coarsest unit that holds it exactly. Half a second is 500 milliseconds, never 500,000 microseconds.
4. Zero is not negative. The only encoding of zero is `00`.

So decoding and then encoding gives back the same bytes, and a value's bytes can be compared for equality.

## 4. Decoding

A decoder reads one complete encoding and refuses it when it breaks any of these rules. The reference implementation checks them in this order and reports the first one broken:

1. **empty**: there are no bytes.
2. **reserved bits**: LENGTH is above 9 or UNIT is above 4.
3. **truncated**: there are fewer bytes than the header demands.
4. **trailing bytes**: there are more bytes than the header demands.
5. **non-canonical**: the seconds start with a zero byte.
6. **fraction out of range**: the count is at or above one second in its unit.
7. **non-canonical**: the count is zero, or a coarser unit holds it exactly, or the encoding is a negative zero.
8. **out of range**: the size is beyond the range of section 1.

A bin holding bytes that fail to decode is a decode failure of its payload, answered like any malformed payload (`malformedParams`, code 3, for a request slot).

## 5. Text form

In JSON projections of wire values (discovery tooling, the CLI's parameter and output trees) and in the generated CLI, a duration is ISO 8601 duration text. This form never appears on the wire.

The grammar is

```
["-"] "P" [n "D"] ["T" [n "H"] [n "M"] [n ["." f] "S"]]
```

with at least one component, at least one after a `T`, each `n` one or more ASCII digits, and `f` 1 to 18 digits. A day is 86,400 seconds. Years, months and weeks have no place in it, and nor have a `+` sign, a comma for the dot, lowercase designators, or a fraction on any component but the seconds.

The canonical text is `PT0S` for zero. Otherwise it is a `-` for a negative span, then `PT`, then the hours, minutes and seconds that are not zero. The hours are not folded into days, and the seconds carry a fraction of up to 18 digits with trailing zeros removed: `PT1H30M`, `PT25H`, `-PT0.5S`, `PT1M0.000000001S`.

## 6. Test vectors

Canonical encodings, each with its canonical text:

| Text | Bytes |
|------|-------|
| `PT0S` | `00` |
| `PT1S` | `01 01` |
| `PT1H30M` | `02 15 18` |
| `-PT0.5S` | `90 01 f4` |
| `PT0.000001S` | `20 00 00 01` |
| `PT1M0.000000001S` | `31 3c 00 00 00 01` |
| `PT25H1M1.0005S` | `23 01 5f cd 00 01 f4` |
| `PT0.000000000000000001S` | `40 00 00 00 00 00 00 00 01` |
| `PT47261439850130342H8M51.687303715884105727S` (the largest) | `49 09 39 2e e8 e9 21 d5 d0 73 09 89 cb 16 8e 13 ff ff` |
| `-PT47261439850130342H8M51.687303715884105728S` (the smallest) | `c9 09 39 2e e8 e9 21 d5 d0 73 09 89 cb 16 8e 14 00 00` |

Encodings a decoder refuses:

| Bytes | Failure |
|-------|---------|
| (none) | empty |
| `0a` | reserved bits (LENGTH 10) |
| `50` | reserved bits (UNIT 5) |
| `02 01` | truncated |
| `01 01 00` | trailing bytes |
| `02 00 01` | non-canonical (a leading zero byte) |
| `11 01 03 e8` | fraction out of range (1,000 milliseconds) |
| `10 00 00` | non-canonical (a fraction of zero) |
| `20 07 a1 20` | non-canonical (500,000 microseconds, which milliseconds hold) |
| `80` | non-canonical (a negative zero) |
| `49 09 39 2e e8 e9 21 d5 d0 73 09 89 cb 16 8e 14 00 00` | out of range (one attosecond past the largest) |
