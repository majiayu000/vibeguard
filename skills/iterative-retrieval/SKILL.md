---
name: iterative-retrieval
description: "Iterative retrieval — 4-stage loop (DISPATCH→EVALUATE→REFINE→LOOP) to pinpoint relevant information in the code base. Up to 3 rounds."
---

# Iterative Retrieval

## Overview

In large code bases, one search is often not enough. This skill iterates through a search loop, gradually narrowing the scope and pinpointing the relevant code.

## When to Activate

- A first search returns too many partially related results or misses the target surface.
- A codebase question spans file names, symbols, docs, and generated artifacts.
- A user needs evidence-backed repository orientation before implementation.

## Red Flags

- The same broad query is repeated without changing terms or scope.
- Low-relevance results are read in depth before high-relevance anchors.
- Search history is lost, so later conclusions cannot be traced back to evidence.

## Checklist

- Start with 2-3 concrete keywords from the user request.
- Score search results before expanding into neighboring files.
- Stop after three rounds with an explicit unresolved-questions list.

## 4 stage cycle

### 1. DISPATCH (distribution search)

- Extract search keywords from requirements
- Choose a search strategy:
  - Glob: Search by filename pattern
  - Grep: search by content keywords
  - AST: Search by code structure (function name, class name)
- Launch multiple searches in parallel

### 2. EVALUATE (evaluation result)

Rate each search result (0-1):

| Fraction | Meaning | Action |
|------|------|------|
| 0.8-1.0 | Highly relevant | Reserved, further reading |
| 0.5-0.7 | Partially related | Reserved, extract key information |
| 0.2-0.4 | Low correlation | Record path, not in depth |
| 0.0-0.1 | Not relevant | Discard |

### 3. REFINE (refined query)

Adjust your search strategy based on the evaluation results:
- Highly relevant results → Expand search in the same directory/same module
- Low relevant results → Change keywords or search strategies
- Discover new clues → Additional searches

### 4. LOOP (loop judgment)

- enough information found → end, output summary
- Insufficient information and rounds < 3 → Back to DISPATCH
- Reached 3 rounds → forced end, output existing information + unresolved issues

## Termination condition

- All key questions already answered
- Highly relevant results cover all aspects of requirements
- Maximum rounds reached (3 rounds)

## Output format

```text
## Search report

### Rounds: N/3

### Discover
| Documentation | Relevance | Key Information |
|------|--------|----------|
| ...  | 0.9    | ...      |

### Not resolved
- <Questions that still need to be confirmed>

### Search History
1. <query> → <number of results>, highest relevance <score>
```

## VibeGuard Integration

- Marking in search results has been implemented (supports L1 search first and write later)
- Mark when duplicate code is found (supports anti-duplication checking)
