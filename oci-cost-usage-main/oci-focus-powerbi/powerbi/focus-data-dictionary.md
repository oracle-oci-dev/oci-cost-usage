# OCI FOCUS Power BI notes

Use the native FOCUS column names. `BilledCost` is the post-discount billed cost;
OCI notes that it excludes taxes and can differ from an invoice. Keep each row,
including correction rows. OCI marks corrections with `lineItem/iscorrection` and
links the amended item using `lineItem/backReference`.

Recommended types: costs as fixed decimal/currency, `BilledQuantity` as decimal,
all periods as UTC datetimes, and identifiers (especially `ResourceId`) as text.
Keep `Tags` as text initially, then split to a child tags dimension only after a
stable tag parsing convention has been agreed.
