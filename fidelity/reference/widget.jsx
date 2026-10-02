// A React component, generated for the fidelity harness.
import React, { useState, useEffect } from "react";
import { formatDate } from "./dates.js";

const PAGE_SIZE = 20;

/**
 * Episodes in pages, newest first.
 * @param {object} props
 */
export default function EpisodeList({ feed, onPick, compact = false }) {
  const [page, setPage] = useState(0);
  const [items, setItems] = useState([]);

  useEffect(() => {
    fetch(`/api/feeds/${feed.id}?page=${page}&size=${PAGE_SIZE}`)
      .then((response) => response.json())
      .then((data) => setItems(data.items));
  }, [feed.id, page]);

  if (items.length === 0) {
    return <p className="empty">No episodes yet.</p>;
  }

  return (
    <>
      <h2 title={feed.title}>{feed.title}</h2>
      {/* The list, one row per episode. */}
      <ul className={compact ? "list compact" : "list"}>
        {items.map((item, index) => (
          <li key={item.guid} onClick={() => onPick(item)}>
            <span className="number">{index + 1 + page * PAGE_SIZE}.</span>
            <Episode.Title text={item.title} />
            <time dateTime={item.pubDate}>{formatDate(item.pubDate)}</time>
          </li>
        ))}
      </ul>
      <button disabled={page === 0} onClick={() => setPage(page - 1)}>
        Newer
      </button>
      <button onClick={() => setPage(page + 1)}>Older &rarr;</button>
    </>
  );
}
