#!/usr/bin/env perl
# Fills <pre data-src="file" data-from="text" [data-to="text"]><code></code></pre>
# blocks in an HTML file with the matching excerpt of a source file.
#
# The excerpt starts at the first line containing data-from, widened upward
# over `///` doc lines. Without data-to it ends where the declaration's braces
# close (or at its `;`). With data-to it ends at the first line containing it.
#
# Usage: tools/sync-snippets.pl [--check] report.html
#   --check  report stale blocks and exit 1 instead of rewriting the file
use strict;
use warnings;

my $check = 0;
if (@ARGV && $ARGV[0] eq '--check')
{
    $check = 1;
    shift @ARGV;
}
my $path = shift @ARGV or die "usage: $0 [--check] report.html\n";
open(my $in, '<:encoding(UTF-8)', $path) or die "$path: $!\n";
my $html = do { local $/; <$in> };
close $in;

(my $base = $path) =~ s{[^/]*$}{};
my ($count, $stale) = (0, 0);

$html =~ s{(<pre\b[^>]*\bdata-src="([^"]+)"[^>]*>)<code>(.*?)</code></pre>}{
    my ($open, $src, $old) = ($1, $2, $3);
    my ($from) = $open =~ /\bdata-from="([^"]*)"/;
    my ($to) = $open =~ /\bdata-to="([^"]*)"/;
    die "$path: block for $src has no data-from\n" unless defined $from;
    my $new = escape(extract($base . $src, unent($from), defined $to ? unent($to) : undef));
    ++$count;
    if ($new ne $old)
    {
        ++$stale;
        print STDERR "stale: $src \"$from\"\n" if $check;
    }
    "$open<code>$new</code></pre>"
}gse;

if ($check)
{
    print "$count snippets, $stale stale\n";
    exit($stale == 0 ? 0 : 1);
}
open(my $out, '>:encoding(UTF-8)', $path) or die "$path: $!\n";
print $out $html;
close $out;
print "$count snippets, $stale updated\n";

# Lines of $file from the line containing $from to the end of that declaration.
sub extract
{
    my ($file, $from, $to) = @_;
    open(my $fh, '<:encoding(UTF-8)', $file) or die "$file: $!\n";
    my @lines = <$fh>;
    close $fh;
    chomp @lines;

    my $at = -1;
    for my $i (0 .. $#lines)
    {
        if (index($lines[$i], $from) >= 0)
        {
            $at = $i;
            last;
        }
    }
    die "$file: no line contains \"$from\"\n" if $at < 0;

    my $start = $at;
    --$start while $start > 0 && $lines[$start - 1] =~ m{^\s*///};

    my $end = -1;
    if (defined $to)
    {
        for my $j ($at .. $#lines)
        {
            if (index($lines[$j], $to) >= 0)
            {
                $end = $j;
                last;
            }
        }
        die "$file: no line after \"$from\" contains \"$to\"\n" if $end < 0;
    }
    else
    {
        my $j = $at;
        ++$j while $j < $#lines && $lines[$j] =~ m{^\s*///};
        my ($depth, $seen) = (0, 0);
        for my $k ($j .. $#lines)
        {
            my $code = $lines[$k];
            $code =~ s{"(?:\\.|[^"\\])*"}{""}g;
            $code =~ s{'(?:\\.|[^'\\])'}{''}g;
            $code =~ s{//.*}{};
            my $opens = () = $code =~ /\{/g;
            my $closes = () = $code =~ /\}/g;
            $seen = 1 if $opens > 0;
            $depth += $opens - $closes;
            if (($seen && $depth == 0) || (!$seen && $code =~ /;\s*$/))
            {
                $end = $k;
                last;
            }
        }
        die "$file: unbalanced braces after \"$from\"\n" if $end < 0;
    }

    my @take = @lines[$start .. $end];
    my $indent;
    for my $l (@take)
    {
        next if $l =~ /^\s*$/;
        my ($lead) = $l =~ /^( *)/;
        $indent = length $lead if !defined $indent || length $lead < $indent;
    }
    $indent //= 0;
    s/^ {0,$indent}// for @take;
    return join("\n", @take);
}

# HTML-escapes code.
sub escape
{
    my ($s) = @_;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    return $s;
}

# Undoes the entities allowed in attribute values.
sub unent
{
    my ($s) = @_;
    $s =~ s/&quot;/"/g;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&amp;/&/g;
    return $s;
}
