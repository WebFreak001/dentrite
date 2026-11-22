/// List virtualization: which rows to build for a scroll position.
///
/// Fixed-height rows (memory, disassembly) need only arithmetic. Variable-height
/// rows (wrapped logs) keep heights in a Fenwick tree for O(log n) offset and
/// index lookups, with an estimate for rows never measured.
module dentrite.virtual;

import std.algorithm.comparison : max, min;
import std.math : floor;

/// Half-open row range `[first, last)`.
struct RowRange
{
    size_t first; /// first row to build
    size_t last;  /// one past the last row to build
}

/// Rows overlapping the viewport, widened by `overscan` rows on each side.
RowRange visibleFixed(double scrollY, double viewH, double rowH, size_t count, size_t overscan = 2)
{
    if (count == 0)
    {
        return RowRange.init;
    }
    size_t first = cast(size_t) floor(max(0.0, scrollY) / rowH);
    size_t last = cast(size_t) floor((max(0.0, scrollY) + viewH) / rowH) + 1;
    first = first > overscan ? first - overscan : 0;
    last = min(count, last + overscan);
    return RowRange(min(first, count), last);
}

/// Fixed rows: 1 M rows of 16 px in a 480 px viewport build about 34 rows.
unittest
{
    RowRange r = visibleFixed(160_000, 480, 16, 1_000_000);
    assert(r.first == 9998 && r.last == 10033);
    assert(visibleFixed(0, 480, 16, 10) == RowRange(0, 10));
    assert(visibleFixed(0, 480, 16, 0) == RowRange(0, 0));
}

/// Row heights with prefix sums. Unmeasured rows count as `estimate`.
final class RowHeights
{
    private double[] tree;   /// Fenwick tree, 1-based
    private float[] heights; /// current height per row
    private float estimate;  /// height assumed before measuring

    /// Creates `count` rows of `estimate` height.
    this(size_t count, float estimate)
    {
        this.estimate = estimate;
        heights = new float[count];
        heights[] = estimate;
        tree = new double[count + 1];
        tree[] = 0;
        foreach (size_t i; 1 .. count + 1)
        {
            tree[i] += estimate;
            size_t j = i + (i & -i);
            if (j <= count)
            {
                tree[j] += tree[i];
            }
        }
    }

    /// Number of rows.
    size_t length() const
    {
        return heights.length;
    }

    /// Records the measured height of row `i`.
    void set(size_t i, float h)
    {
        double delta = h - heights[i];
        heights[i] = h;
        for (size_t k = i + 1; k < tree.length; k += k & -k)
        {
            tree[k] += delta;
        }
    }

    /// Adds a row at the end, as a log or console does.
    void append(float h)
    {
        size_t k = heights.length + 1;
        heights ~= h;
        tree ~= h + prefix(k - 1) - prefix(k - (k & -k));
    }

    /// Height of row `i`.
    float height(size_t i) const
    {
        return heights[i];
    }

    /// Sum of the first `n` row heights.
    private double prefix(size_t n) const
    {
        double s = 0;
        for (size_t k = n; k > 0; k -= k & -k)
        {
            s += tree[k];
        }
        return s;
    }

    /// Top of row `i` in content coordinates.
    double offsetOf(size_t i) const
    {
        return prefix(i);
    }

    /// Total content height.
    double total() const
    {
        return prefix(heights.length);
    }

    /// Row containing content position `y`, clamped to the last row.
    size_t indexAt(double y) const
    {
        size_t n = heights.length;
        size_t step = 1;
        while (step * 2 <= n)
        {
            step *= 2;
        }
        size_t pos;
        double rest = y;
        for (; step > 0; step /= 2)
        {
            if (pos + step <= n && tree[pos + step] <= rest)
            {
                pos += step;
                rest -= tree[pos];
            }
        }
        return n == 0 ? 0 : min(pos, n - 1);
    }

    /// Rows overlapping the viewport plus `overscan` on each side.
    RowRange visible(double scrollY, double viewH, size_t overscan = 2) const
    {
        if (heights.length == 0)
        {
            return RowRange.init;
        }
        size_t first = indexAt(max(0.0, scrollY));
        size_t last = indexAt(max(0.0, scrollY) + viewH) + 1;
        first = first > overscan ? first - overscan : 0;
        return RowRange(first, min(heights.length, last + overscan));
    }
}

/// Scroll position expressed relative to a row, so it survives height changes above.
struct Anchor
{
    size_t row;   /// row at the top of the viewport
    double delta; /// pixels scrolled past the top of that row
}

/// Anchor for the row at the top of the viewport.
Anchor capture(const RowHeights rows, double scrollY)
{
    size_t r = rows.indexAt(scrollY);
    return Anchor(r, scrollY - rows.offsetOf(r));
}

/// Scroll position that puts the anchor back where it was.
double restore(const RowHeights rows, Anchor a)
{
    return rows.offsetOf(a.row) + a.delta;
}

// Variable rows: Fenwick sums match a plain sum and lookups invert offsets.
unittest
{
    enum size_t n = 100_000;
    RowHeights rows = new RowHeights(n, 16);
    foreach (size_t i; 0 .. n)
    {
        if (i % 7 == 0)
        {
            rows.set(i, 16 * (1 + i % 5));
        }
    }
    double naive = 0;
    foreach (size_t i; 0 .. n)
    {
        if (i % 9973 == 0)
        {
            assert(rows.offsetOf(i) == naive);
            assert(rows.indexAt(naive) == i);
            assert(rows.indexAt(naive + rows.height(i) - 0.5) == i);
        }
        naive += rows.height(i);
    }
    assert(rows.total == naive);
    assert(rows.indexAt(naive + 1000) == n - 1);
}

// Appending rows keeps the sums correct.
unittest
{
    RowHeights rows = new RowHeights(0, 16);
    double naive = 0;
    foreach (size_t i; 0 .. 1000)
    {
        float h = 16 + (i % 3) * 16;
        rows.append(h);
        naive += h;
        assert(rows.total == naive);
    }
    assert(rows.indexAt(rows.offsetOf(500)) == 500);
}

// Anchoring: rows above the viewport grow after measuring, the visible row stays put.
unittest
{
    RowHeights rows = new RowHeights(10_000, 16);
    double scrollY = 5000 * 16 + 5;
    Anchor a = capture(rows, scrollY);
    assert(a.row == 5000 && a.delta == 5);
    foreach (size_t i; 4990 .. 5000)
    {
        rows.set(i, 48);
    }
    double fixedY = restore(rows, a);
    assert(fixedY == scrollY + 10 * 32);
    assert(rows.indexAt(fixedY) == 5000);
}
