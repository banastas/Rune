<?php
// A feed page, generated for the fidelity harness.
declare(strict_types=1);

namespace Feeds;

use Feeds\Store\FeedStore;

const PAGE_SIZE = 20;

final class Page
{
    private array $episodes = [];

    public function __construct(private FeedStore $store, public string $title = 'Episodes')
    {
        $this->episodes = $store->newest(PAGE_SIZE);
    }

    public function count(): int
    {
        return count($this->episodes);
    }

    /** @return list<array{title: string, url: ?string}> */
    public function rows(): array
    {
        return array_map(fn ($e) => ['title' => $e->title, 'url' => $e->url ?? null], $this->episodes);
    }
}

$page = new Page(new FeedStore(__DIR__ . '/cache'));
$empty = $page->count() === 0;
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <title><?= htmlspecialchars($page->title) ?></title>
</head>
<body>
  <h1 class="title"><?php echo $page->title; ?></h1>
  <?php if ($empty): ?>
    <p>No episodes yet.</p>
  <?php else: ?>
    <ul>
      <?php foreach ($page->rows() as $i => $row): ?>
        <li data-index="<?= $i ?>"><a href="<?= $row['url'] ?>"><?= $row['title'] ?></a></li>
      <?php endforeach; ?>
    </ul>
  <?php endif; ?>
</body>
</html>
