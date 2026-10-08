-- Episode report, generated for the fidelity harness.
CREATE TABLE IF NOT EXISTS episodes (
    id INTEGER PRIMARY KEY,
    feed_id INTEGER NOT NULL REFERENCES feeds (id),
    title VARCHAR(200) NOT NULL,
    published_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    duration_seconds INT CHECK (duration_seconds >= 0),
    explicit BOOLEAN DEFAULT FALSE
);

CREATE INDEX idx_episodes_feed ON episodes (feed_id, published_at DESC);

INSERT INTO episodes (feed_id, title, duration_seconds)
VALUES (1, 'Plain Text Forever', 2537),
       (1, 'Colors and Themes', 2410);

/* The newest episode of each feed, with how many it has. */
SELECT f.title AS feed,
       e.title AS newest,
       COUNT(*) OVER (PARTITION BY e.feed_id) AS total,
       ROUND(AVG(e.duration_seconds) / 60.0, 1) AS average_minutes
FROM episodes AS e
JOIN feeds f ON f.id = e.feed_id
WHERE e.published_at > NOW() - INTERVAL '30 days'
  AND e.title NOT LIKE '%draft%'
  AND e.explicit IS NULL OR e.explicit = TRUE
GROUP BY f.title, e.title, e.feed_id
HAVING COUNT(*) > 1
ORDER BY f.title ASC, e.title DESC
LIMIT 20;

UPDATE episodes SET duration_seconds = 0 WHERE duration_seconds IS NULL;
DELETE FROM episodes WHERE feed_id IN (SELECT id FROM feeds WHERE active = FALSE);
