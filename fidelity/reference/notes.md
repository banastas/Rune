# Vendor review

Draft for **Sam**, due *Friday*. The numbers are in [the sheet](https://example.com/q4) and `config.json`.

## Open items

- [x] Invoice attached
- [ ] QA sign-off
  - ask about the August total
- Follow up with **Alex** on _quiet hours_

1. Run the totals
2. Paste them below
3. Send

> We can ship on Friday if QA signs off.
> Everything else is ready.

### Deploy

```bash
ssh me@seedbox 'df -h ~/files'
rsync -av --progress ./dist/ me@seedbox:~/www/ && echo "done"
```

```js
const total = invoices.reduce((sum, { amount }) => sum + amount, 0);
console.log(`Total: ${total.toFixed(2)}`);
```

```xml
<enclosure url="https://cdn.example.com/q4.mp3" length="1840" type="audio/mpeg"/>
```

```python
total = sum(len(feed.episodes) for feed in feeds)
print(f"{total:,} episodes in {len(feeds)} feeds")
```

```yaml
retries: 3
sources: [main, archive]
```

---

Some ~~old~~ notes, a line with `inline code`, and a footnote.[^1]

| Month | Total |
| ----- | ----: |
| July  | 1,840 |
| Aug   | 2,710 |

[^1]: From the Q3 review.
