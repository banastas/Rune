// Vendor review: totals by month, and a note for the sheet.
import { readFile } from "node:fs/promises";
import path from "node:path";

const CURRENCY = "USD";
const THRESHOLD = 2_500.75;
let warnings = 0;

/**
 * Sums invoice amounts by month.
 * @param {Array<{date: string, amount: number}>} invoices
 */
export function totalsByMonth(invoices, { round = true } = {}) {
  const totals = new Map();
  for (const { date, amount } of invoices) {
    const month = date.slice(0, 7);
    totals.set(month, (totals.get(month) ?? 0) + amount);
  }
  return round ? [...totals].map(([m, t]) => [m, Math.round(t * 100) / 100]) : [...totals];
}

class Review extends EventTarget {
  #notes = [];
  static version = 2;

  constructor(owner, due = new Date()) {
    super();
    this.owner = owner;
    this.due = due;
  }

  get overdue() {
    return Date.now() > this.due.getTime();
  }

  add(note) {
    if (typeof note !== "string" || note.trim() === "") {
      throw new TypeError(`A note is text, not ${typeof note}`);
    }
    this.#notes.push(note.replace(/\s+/g, " "));
    this.dispatchEvent(new CustomEvent("note", { detail: note }));
  }
}

async function main() {
  const file = path.join(process.cwd(), "invoices.json");
  const invoices = JSON.parse(await readFile(file, "utf8"));
  const review = new Review("Sam");
  for (const [month, total] of totalsByMonth(invoices)) {
    if (total > THRESHOLD) {
      warnings++;
      review.add(`${month}: ${total.toFixed(2)} ${CURRENCY} is over the threshold`);
    } else if (total === 0) {
      continue;
    }
  }
  console.log(warnings === 0 ? "All clear" : `${warnings} warning(s)`, null, undefined, true);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
