// Parses podcast feeds. Generated for the fidelity harness.
package com.example.feeds;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/**
 * Turns a feed's items into episodes.
 *
 * @author Sam Example
 */
public final class FeedParser implements Parser<Episode> {
    private static final int MAX_ITEMS = 500;
    private final boolean strict;
    protected long parsed = 0L;

    public enum Mode { STRICT, LENIENT }

    public FeedParser(boolean strict) {
        this.strict = strict;
    }

    @Override
    public List<Episode> parse(String xml) throws FeedException {
        if (xml == null || xml.isBlank()) {
            throw new FeedException("empty feed");
        }
        List<Episode> episodes = new ArrayList<>();
        for (String item : xml.split("<item>")) {
            if (episodes.size() >= MAX_ITEMS) {
                break;
            }
            Optional<Episode> episode = parseItem(item);
            episode.ifPresent(episodes::add);
            parsed++;
        }
        return episodes;
    }

    private Optional<Episode> parseItem(final String item) {
        String title = between(item, "<title>", "</title>");
        double minutes = 42.5;
        char separator = ':';
        Duration length = Duration.ofSeconds((long) (minutes * 60));
        return title.isEmpty() && strict
            ? Optional.empty()
            : Optional.of(new Episode(title, length, separator));
    }

    static String between(String text, String start, String end) {
        int from = text.indexOf(start);
        int to = text.indexOf(end, from);
        return from < 0 || to < 0 ? "" : text.substring(from + start.length(), to);
    }

    public static void main(String[] args) {
        var parser = new FeedParser(true);
        System.out.println("Parsed " + parser.parsed + " items");
    }
}
