# Spec Delta

## Purpose

Keeps per-bucket summaries of the readings that plots draw: min, max and mean for numbers, and the states that occurred for enums and bools. The summaries are kept up to date in the background, so a historical plot of a long recording no longer has to scan every reading in its window.

## ADDED Requirements

### Requirement: Number aggregates
For each parameter of type `double`, `int` or `scaled`, the system SHALL store per bucket the min, the max, the sum and count of the readings (mean = sum / count), when the min and the max occurred, and the bucket's first and last value with their timestamps. Values of a `scaled` parameter SHALL be aggregated as stored (unscaled).

#### Scenario: Bucket of a double parameter
- **WHEN** a `double` parameter has readings 1.0, 4.0 and 2.5 within one 1-minute bucket, at t1 < t2 < t3, and the aggregates have been refreshed
- **THEN** the bucket reads min 1.0 at t1, max 4.0 at t2, mean 2.5, count 3, first 1.0 at t1 and last 2.5 at t3

#### Scenario: Equal extremes
- **WHEN** a bucket holds the lowest value twice, at t1 and later at t2
- **THEN** the bucket's min reads as occurring at t1, however the readings are stored or compressed

#### Scenario: Readings with the same timestamp
- **WHEN** two readings of a parameter share a timestamp and hold different values
- **THEN** the bucket's first value is the one with the lower reading id and its last value the one with the higher id, on every refresh

#### Scenario: Very large values
- **WHEN** a `double` parameter reads 1.0, 1e308 and 3.0 within one bucket
- **THEN** the refresh succeeds, 1e308 is left out like NaN, and the bucket reads min 1.0, max 3.0 and count 2

#### Scenario: Integers beyond float precision
- **WHEN** an `int` parameter reads values above 2^53
- **THEN** they are aggregated as float8, and two values that differ by less than float8 precision count as equal

#### Scenario: Scaled parameter
- **WHEN** a `scaled` parameter with scale 0.1 stores the integers 10 and 30 in one bucket
- **THEN** the bucket reads min 10, max 30 and mean 20, and applying the scale is left to the reader

### Requirement: State aggregates
For each parameter of type `enum` or `bool`, the system SHALL store per bucket one entry for each state that occurs, with the timestamps of its first and last reading and its count. Bool states SHALL read as 0 (false) and 1 (true).

#### Scenario: Enum changes state within a bucket
- **WHEN** an `enum` parameter reads 0, 2, 0 within one bucket
- **THEN** the bucket has two entries: state 0 with the first and the third reading's timestamps and count 2, and state 2 with count 1

#### Scenario: Fractional enum value
- **WHEN** an `enum` member of a struct holds 1.5
- **THEN** that value is in no state aggregate

#### Scenario: Enum value out of range
- **WHEN** an `enum` member of a struct holds 1e30
- **THEN** the refresh succeeds, that value is in no state aggregate, and the struct's other readings are aggregated

#### Scenario: Enum reading that did not fit its type
- **WHEN** an `enum` parameter receives a string, which is stored as JSON
- **THEN** that reading produces no state entry, not even an empty one

#### Scenario: Int is not treated as a state
- **WHEN** an `int` parameter's readings are aggregated
- **THEN** they appear only in the number aggregates, never as states

### Requirement: Array element aggregates
For a parameter that is an array of `double`, `int`, `scaled`, `enum` or `bool`, the system SHALL aggregate every element on its own, as for a scalar of the element type, for any array length. Elements SHALL be identified by their 1-based position.

#### Scenario: Per-element extremes
- **WHEN** a 3-element `double` array reads [1, 5, 9] and then [3, 2, 9] within one bucket
- **THEN** element 1 reads min 1 and max 3, element 2 min 2 and max 5, and element 3 min 9 and max 9

#### Scenario: Readings of different length
- **WHEN** a bucket holds a 2-element reading and a 3-element reading of the same parameter
- **THEN** elements 1 and 2 count both readings and element 3 counts one

### Requirement: Array length aggregates
For every aggregated array, at top level or as a struct or tuple member, the system SHALL store the length of each reading as element 0 in the number aggregates (min, max, mean, first and last, with timestamps, and count). This SHALL include enum and bool arrays, whose elements are otherwise state aggregates.

#### Scenario: Ragged array shrinks within a bucket
- **WHEN** a `double` array with minlen 1 and maxlen 3 reads [1, 2, 3] at t1 and then [4, 5] at t2 within one bucket
- **THEN** element 0 reads min 2, max 3, first 3 at t1, last 2 at t2 and count 2, and element 3's last value is 3 at t1

#### Scenario: Enum array length
- **WHEN** an array of `enum` reads [0, 1] and then [1] within one bucket
- **THEN** element 0 is in the number aggregates with min 1 and max 2, and elements 1 and 2 are in the state aggregates

#### Scenario: Fixed-length array
- **WHEN** every reading of an array has 50 elements
- **THEN** element 0 reads min 50 and max 50, and its count equals the number of readings in the bucket

#### Scenario: Empty array
- **WHEN** an array reads [] within a bucket
- **THEN** element 0 counts that reading with length 0, and no other element counts it

#### Scenario: Array reading that did not fit its type
- **WHEN** an array of `int` receives a reading containing a float, which is stored as JSON
- **THEN** that reading is in no aggregate, element 0 included

### Requirement: Struct and tuple member aggregates
For a `struct` or `tuple` parameter, the system SHALL aggregate each direct member that is a number, an enum, a bool, or an array of those, as it would that type on its own. Struct members SHALL be keyed by name, and tuple members by 0-based position. Members nested deeper SHALL NOT be aggregated.

#### Scenario: Struct with number, enum and array members
- **WHEN** a struct has members `temperature` (double), `mode` (enum), `spectrum` (array of double) and `limits` (struct)
- **THEN** `temperature` gets number aggregates, `mode` gets state aggregates, `spectrum` gets per-element number aggregates, and `limits` and its members get none

#### Scenario: Tuple member
- **WHEN** a tuple's datainfo declares `[double, enum]`
- **THEN** member `0` gets number aggregates and member `1` gets state aggregates

#### Scenario: Whole-number float in an integer member
- **WHEN** an `int` member of a struct holds 2.0 in one reading and 1000.0 in another
- **THEN** both are counted, as 2 and 1000, because a whole-number float in a member can't reliably be told from an integer once stored; a top-level `int` that receives a float is kept as JSON and not aggregated

#### Scenario: Member with an unexpected value
- **WHEN** a struct reading holds a string for a member whose datainfo declares `double`
- **THEN** that member's value is left out of that bucket's aggregates, and the struct's other members are still aggregated

#### Scenario: Member nested two levels deep
- **WHEN** a struct member `limits` is a struct whose member `range` is itself a struct of doubles
- **THEN** neither `limits`, `range` nor any of their members gets aggregates

#### Scenario: Member number too large
- **WHEN** a `double` member reads 1.0, then a 400-digit integer, then 1e-400, in one bucket
- **THEN** the refresh succeeds, and that member reads min 1.0, max 1.0 and count 1

#### Scenario: Reading of the wrong shape
- **WHEN** a `struct` parameter's reading holds a JSON array instead of an object, or a `tuple` parameter's reading holds an object
- **THEN** that reading is in no aggregate, the refresh succeeds, and the parameter's other readings are aggregated

### Requirement: Readings without aggregates
The system SHALL NOT aggregate strings, arrays of strings, struct or tuple values as a whole (only their direct members, as above), arrays of structs or tuples, or readings kept as JSON because their value did not fit the declared type. NaN, infinite values and numbers with an absolute value of 1e290 or more SHALL be left out of number aggregates, and so SHALL member numbers that float8 cannot hold: nonzero values that round to zero, and values beyond its largest finite number.

#### Scenario: Value that did not fit its type
- **WHEN** an `int` parameter receives a float, which is stored as JSON
- **THEN** that reading is in no aggregate, and the parameter's other readings are

#### Scenario: NaN reading
- **WHEN** a `double` parameter reads 1.0, NaN and 3.0 in one bucket
- **THEN** the bucket reads min 1.0, max 3.0, mean 2.0 and count 2

### Requirement: Aggregate tiers kept up to date
The system SHALL keep the aggregates at a 1-minute tier and a 1-hour tier, refreshed in the background. A refresh SHALL pick up new readings, late readings and deleted readings, including readings removed with their parameter.

#### Scenario: New readings are materialized
- **WHEN** readings arrive for a parameter and the refresh policies have run
- **THEN** the 1-minute and the 1-hour tier both hold the buckets those readings fall in

#### Scenario: Late reading
- **WHEN** a reading is inserted into a bucket that both tiers have already materialized, and the policies run again
- **THEN** the 1-minute and the 1-hour bucket both include it

#### Scenario: Parameter deleted
- **WHEN** a parameter is deleted together with its readings and the policies have run
- **THEN** none of the tiers return buckets for that parameter

### Requirement: Reading aggregates for a window
The system SHALL return a parameter's aggregates for a time window at a requested bucket width that is a whole multiple of a tier, rolled up from the coarsest tier that divides it. Widths not a multiple of 1 minute SHALL be rejected, and so SHALL a request for a kind of aggregate the parameter does not have.

#### Scenario: 15-minute buckets
- **WHEN** 15-minute buckets are requested for a 72 h window of a `double` parameter
- **THEN** each returned bucket's min, max, mean, first and last equal those computed from the raw readings in that bucket

#### Scenario: Width served from the 1-hour tier
- **WHEN** 6-hour buckets are requested
- **THEN** they are rolled up from the 1-hour tier and match the same buckets rolled up from the 1-minute tier, with means equal within floating-point tolerance

#### Scenario: Width below a tier
- **WHEN** 30-second buckets are requested
- **THEN** the request is rejected as an error, so the caller can fall back to raw thinning

#### Scenario: Kind of aggregate the parameter does not have
- **WHEN** number aggregates are requested for a scalar `enum` or a `string` parameter
- **THEN** the request is rejected as an error

### Requirement: Window edges and completeness
The request window SHALL be normalized by flooring both edges to the bucket width, giving the half-open window [floor(from), floor(to)), and only buckets that lie fully inside the normalized window SHALL be returned. Each result SHALL state the tier's materialization high-water mark and SHALL return no bucket past it. Late readings and deletes SHALL appear after the next successful refresh that covers them.

#### Scenario: Window past the materialized end
- **WHEN** the requested window ends after the newest materialized bucket
- **THEN** only buckets that end at or before the materialized end are returned, and the result states when the materialized data ends

#### Scenario: Unaligned window
- **WHEN** 15-minute buckets are requested from 10:07 to 11:52
- **THEN** the window is normalized to 10:00–11:45, the buckets starting at 10:00, 10:15, … 11:30 are returned, and the bucket starting at 11:45 is not

#### Scenario: Never refreshed
- **WHEN** a tier has not been refreshed yet
- **THEN** the result states no materialized end and returns no buckets
