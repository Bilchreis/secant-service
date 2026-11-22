---
name: use-sobelow
description: "Sobelow security rules for Phoenix: XSS, SQL injection, unsafe atom/binary handling, CSRF and config findings. Load when handling user input in controllers, LiveViews or raw SQL, when `mix sobelow` reports a finding, or when editing .sobelow-skips."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

### sobelow

- [sobelow](references/sobelow/sobelow.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p sobelow
```

## Available Mix Tasks

- `mix sobelow`
<!-- usage-rules-skill-end -->
