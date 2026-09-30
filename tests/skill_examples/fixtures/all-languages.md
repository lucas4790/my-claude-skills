---
name: all-languages
description: Fixture for tests/skill_examples - one valid block per tested language, plus fences that are not tested.
---

# All languages

## Shell

```bash
set -euo pipefail
# a comment, not a heading
name="world"
printf 'hello %s\n' "$name"
kubectl -n <namespace> get pods
```

```sh
#!/bin/sh
if [ -n "${HOME:-}" ]; then echo "home"; fi
```

## Python

```python
def greet(name: str) -> str:
    return f"hello {name}"


print(greet("world"))
```

## Data

### YAML

```yaml
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
---
second: document
```

### JSON

~~~json
{"name": "fixture", "values": [1, 2, 3]}
~~~

## PowerShell

1. In a list item:

   ```powershell
   $items = @(1, 2, 3)
   $items | ForEach-Object { $_ * 2 }
   ```

## Not tested

```csharp
var x = 1;
```

```
plain text
```

````markdown
```bash
this inner fence belongs to the markdown block
```
````
