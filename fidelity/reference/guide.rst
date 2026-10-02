============
Feed Tools
============

A guide, generated for the fidelity harness. See `the website <https://example.com/feeds>`_
and the :doc:`installation` page.

Getting started
===============

Install the tools with ``pip install feed-tools``, then run:

.. code-block:: bash

   feed sync --verbose

Options
-------

- ``--retries N``: how many times to try a feed (default *3*).
- ``--verbose``: say what's happening.
- **--dry-run**: fetch, but write nothing.

1. Fetch the feeds.
2. Filter the episodes.

.. note::

   Feeds are cached for an hour.

.. _settings:

Settings
--------

=========  =======  ===========
Name       Type     Default
=========  =======  ===========
retries    int      3
timeout    float    2.5
=========  =======  ===========

.. This is a comment, not shown.

Footnotes like this one [#]_ and references like settings_ work too.

.. [#] Added in version 1.4.
