"""
ai_insight_generator.py

Reads the flagged products/categories from ai/flagged_items.csv (built by
sql/08_ai_flagged_items.sql), asks Claude to summarize why each item was
flagged and what an analyst should investigate, then checks every answer
against the actual SQL numbers before accepting it.

The SQL results are the source of truth. The AI only writes summaries, and
any summary that contradicts or goes beyond the data is marked REJECTED.

Setup (once):
    pip install -r requirements.txt
    set ANTHROPIC_API_KEY in your environment (never put the key in this file)

Run:
    python ai_insight_generator.py --dry-run     # show the prompts, no API calls
    python ai_insight_generator.py               # call the API for every item
    python ai_insight_generator.py --limit 3     # only the first 3 items
"""

import argparse
import csv
import json
import re
import sys

import anthropic

MODEL = "claude-opus-5"

INPUT_PATH = "ai/flagged_items.csv"
OUTPUT_PATH = "ai/ai_insights.csv"

# ---------------------------------------------------------------------------
# The model's job. It only sees the metrics we send, and is told not to
# invent anything the dataset doesn't contain.
# ---------------------------------------------------------------------------
SYSTEM_PROMPT = """You are assisting a retail Buying & Planning analyst.

You will receive the metrics for one product (SKU) or product category that was
flagged by a SQL analysis of H&M transaction data. Based ONLY on the metrics
provided, summarize why the item was flagged and suggest what the analyst should
investigate next.

Rules:
- Use only the numbers provided. Do not calculate new percentages or invent figures.
- Do not state or assume inventory levels, stock availability, costs, margins,
  profit, returns, promotions, markdowns, or customer information. The dataset
  does not contain them. You MAY suggest the analyst check these in internal
  systems, but only in the suggested follow-up, never as a fact in the summary.
- "Sales" is a scaled index, not currency. Never use currency symbols.
- L4W = last 4 weeks, P4W = the previous 4 weeks, LY = the same 4 weeks last year.
  The data ends in late September, so compare with LY before calling a change
  seasonal or real.
- If a percentage change is based on very few units, say the base is too small
  to draw conclusions.
- Keep the summary to 1-2 sentences and the follow-up to 1-2 sentences.
- Copy item_id, flag and pct_change_4w exactly from the input."""

# Structured output: the API guarantees the reply matches this JSON schema.
OUTPUT_SCHEMA = {
    "type": "object",
    "properties": {
        "item_id": {"type": "string"},
        "item_name": {"type": "string"},
        "flag": {"type": "string"},
        "pct_change_4w": {"type": ["number", "null"]},
        "ai_summary": {"type": "string"},
        "suggested_follow_up": {"type": "string"},
    },
    "required": ["item_id", "item_name", "flag", "pct_change_4w",
                 "ai_summary", "suggested_follow_up"],
    "additionalProperties": False,
}

# Metrics sent to the model (CSV column -> label the model sees)
METRIC_LABELS = {
    "units_l4w": "Units sold, last 4 weeks (L4W)",
    "units_p4w": "Units sold, previous 4 weeks (P4W)",
    "sales_l4w": "Sales index, L4W",
    "sales_p4w": "Sales index, P4W",
    "pct_change_units": "Unit % change, L4W vs P4W",
    "units_per_week": "Sales velocity, units per week over the last 12 weeks",
    "weeks_on_sale": "Weeks on sale in the last 12 weeks",
    "units_ly4w": "Units sold, same 4 weeks last year (LY)",
    "pct_vs_ly": "Unit % change vs LY (for a SKU: its product type's change vs LY)",
}

# Words that would mean the summary claims something the data can't support.
FORBIDDEN_IN_SUMMARY = [
    "inventory", "in stock", "out of stock", "stockout", "stock level",
    "margin", "profit", "cost", "sell-through", "weeks of supply",
    "promotion", "discount", "markdown", "returns", "customer", "$",
]

UP_WORDS = ["increase", "grew", "growth", "growing", "rising", "rose", "surge", "jump"]
DOWN_WORDS = ["decrease", "decline", "declining", "fell", "drop", "falling", "down "]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def to_number(value):
    """CSV values arrive as text; convert to float, or None if blank."""
    if value is None or value.strip() == "":
        return None
    return float(value)


def build_prompt(row):
    """Turn one CSV row into the user message sent to the model."""
    lines = [
        f"item_level: {row['item_level']}",
        f"item_id: {row['item_id']}",
        f"item_name: {row['item_name']}",
        f"product_type: {row['product_type']}",
    ]
    if row["department"]:
        lines.append(f"department: {row['department']}")
    lines.append(f"flag: {row['flag']}")
    lines.append(f"pct_change_4w: {row['pct_change_units'] or 'null'}")
    lines.append("")
    lines.append("Metrics:")
    for column, label in METRIC_LABELS.items():
        if row[column]:
            lines.append(f"- {label}: {row[column]}")
    return "\n".join(lines)


def ask_claude(client, row):
    """Send one item to Claude and return the parsed JSON answer."""
    response = client.beta.messages.create(
        model=MODEL,
        max_tokens=16000,
        # If the request is ever declined, retry it on another model in the
        # same call instead of failing.
        betas=["server-side-fallback-2026-06-01"],
        fallbacks=[{"model": "claude-opus-4-8"}],
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": build_prompt(row)}],
        output_config={"format": {"type": "json_schema", "schema": OUTPUT_SCHEMA}},
    )
    if response.stop_reason == "refusal":
        raise ValueError("model declined the request")
    if response.stop_reason == "max_tokens":
        raise ValueError("response was cut off (max_tokens)")

    text = next(block.text for block in response.content if block.type == "text")
    return json.loads(text)


# ---------------------------------------------------------------------------
# Validation: compare the AI answer with the SQL numbers
# ---------------------------------------------------------------------------
def validate(row, answer):
    """Return a list of problems. An empty list means the answer passed."""
    problems = []

    # 1. The echoed fields must match the input exactly.
    if answer["item_id"] != row["item_id"]:
        problems.append(f"item_id changed: {answer['item_id']!r}")
    if answer["flag"] != row["flag"]:
        problems.append(f"flag changed: {answer['flag']!r} (SQL: {row['flag']!r})")

    sql_pct = to_number(row["pct_change_units"])
    ai_pct = answer["pct_change_4w"]
    if (sql_pct is None) != (ai_pct is None) or (
        sql_pct is not None and abs(ai_pct - sql_pct) > 0.5
    ):
        problems.append(f"pct_change_4w {ai_pct} does not match SQL {sql_pct}")

    summary = answer["ai_summary"]
    summary_lower = summary.lower()

    # 2. Every number in the summary must be one of the provided metrics.
    #    Period lengths (4, 8, 12, 52 weeks) are allowed. Names are removed
    #    first, because some contain digits (e.g. "Greta Thong ... 3p").
    allowed = [to_number(row[c]) for c in METRIC_LABELS if to_number(row[c]) is not None]
    allowed += [4, 8, 12, 52]
    text_to_check = summary
    for name in (row["item_name"], row["item_id"], row["product_type"], row["department"]):
        if name:
            text_to_check = text_to_check.replace(name, "")
    for match in re.findall(r"-?\d[\d,]*\.?\d*", text_to_check):
        number = float(match.replace(",", ""))
        if not any(abs(abs(number) - abs(a)) <= max(1.0, 0.01 * abs(a)) for a in allowed):
            problems.append(f"number {match} in summary is not in the SQL results")

    # 3. The summary must not state facts the dataset doesn't contain.
    for term in FORBIDDEN_IN_SUMMARY:
        if term in summary_lower:
            problems.append(f"summary mentions unsupported topic: {term!r}")

    # 4. The direction of change must match the data (simple keyword check).
    if sql_pct is not None:
        says_up = any(w in summary_lower for w in UP_WORDS)
        says_down = any(w in summary_lower for w in DOWN_WORDS)
        if sql_pct < 0 and says_up and not says_down:
            problems.append("summary describes growth, but units fell")
        if sql_pct > 0 and says_down and not says_up:
            problems.append("summary describes a decline, but units rose")

    return problems


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="AI summaries for flagged items")
    parser.add_argument("--input", default=INPUT_PATH)
    parser.add_argument("--output", default=OUTPUT_PATH)
    parser.add_argument("--limit", type=int, help="only process the first N items")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the prompts without calling the API")
    args = parser.parse_args()

    with open(args.input, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    if args.limit:
        rows = rows[: args.limit]

    if args.dry_run:
        for row in rows:
            print("=" * 70)
            print(build_prompt(row))
        print(f"\n{len(rows)} prompts shown. No API calls were made.")
        return

    client = anthropic.Anthropic()   # reads ANTHROPIC_API_KEY from the environment
    results = []

    for i, row in enumerate(rows, start=1):
        print(f"[{i}/{len(rows)}] {row['item_name']} ...", flush=True)
        try:
            answer = ask_claude(client, row)
            problems = validate(row, answer)
        except anthropic.AuthenticationError:
            sys.exit("API key missing or invalid. Set the ANTHROPIC_API_KEY environment variable.")
        except anthropic.RateLimitError:
            answer, problems = {}, ["rate limited - try again later or use --limit"]
        except anthropic.APIStatusError as e:
            answer, problems = {}, [f"API error {e.status_code}: {e.message}"]
        except anthropic.APIConnectionError:
            answer, problems = {}, ["could not connect to the API"]
        except (ValueError, KeyError, StopIteration) as e:
            answer, problems = {}, [f"unusable response: {e}"]

        status = "PASS" if not problems else "REJECTED"
        results.append({
            **row,
            "ai_summary": answer.get("ai_summary", ""),
            "suggested_follow_up": answer.get("suggested_follow_up", ""),
            "validation_status": status,
            "validation_notes": "; ".join(problems),
        })

        pct = row["pct_change_units"]
        print(f"  Product: {row['item_name']} ({row['item_id']})")
        print(f"  Flag: {row['flag']}")
        print(f"  4-week change: {pct + '%' if pct else 'n/a'}")
        print(f"  AI Summary: {answer.get('ai_summary', '-')}")
        print(f"  Suggested Follow-up: {answer.get('suggested_follow_up', '-')}")
        print(f"  Validation: {status} {('- ' + '; '.join(problems)) if problems else ''}\n")

    with open(args.output, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(results[0].keys()))
        writer.writeheader()
        writer.writerows(results)

    passed = sum(r["validation_status"] == "PASS" for r in results)
    print(f"Done: {passed} of {len(results)} passed validation. Saved to {args.output}")


if __name__ == "__main__":
    main()
