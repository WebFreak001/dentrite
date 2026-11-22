#!/usr/bin/env perl
# Fills the ```d fence after each
#   <!-- src="file" from="text" [to="text"] -->
# line of a Markdown file with the matching excerpt of a source file, relative
# to the Markdown file.
#
# The excerpt starts at the first line containing `from`, widened upward over
# `///` doc lines. Without `to` it ends where the declaration's braces close
# (or at its `;`). With `to` it ends at the first line containing it.
# Same rules as research/tools/sync-snippets.pl.
#
# Usage: tools/sync-snippets.pl [--check] FILE.md...
#   --check  report stale blocks and exit 1 instead of rewriting the files
use strict;
use warnings;

my $check = 0;
if (@ARGV && $ARGV[0] eq '--check')
{
    $check = 1;
    shift @ARGV;
}
die "usage: $0 [--check] FILE.md...\n" unless @ARGV;

my ($count, $stale) = (0, 0);
for my $path (@ARGV)
{
    open(my $in, '<:encoding(UTF-8)', $path) or die "$path: $!\n";
    my $md = do { local $/; <$in> };
    close $in;
    (my $base = $path) =~ s{[^/]*$}{};

    my $markers = () = $md =~ m{^<!--\s*src=}gm;
    my $matched = 0;
    my $out = '';
    my $changed = 0;
    while ($md =~ m{\G(.*?)(<!--\s*src="([^"]+)"\s+from="([^"]*)"(?:\s+to="([^"]*)")?\s*-->\n)```d\n(.*?)```\n}gsc)
    {
        my ($before, $marker, $src, $from, $to, $old) = ($1, $2, $3, $4, $5, $6);
        my $new = extract($base . $src, $from, $to) . "\n";
        ++$count;
        ++$matched;
        if ($new ne $old)
        {
            ++$stale;
            $changed = 1;
            print STDERR "stale: $path: $src \"$from\"\n" if $check;
        }
        $out .= $before . $marker . "```d\n" . $new . "```\n";
    }
    $out .= substr($md, pos($md) // 0);
    die "$path: $matched of $markers snippet markers parse, quotes in from or to are not allowed\n"
        if $matched != $markers;
    if ($check == 0 && $changed)
    {
        open(my $fh, '>:encoding(UTF-8)', $path) or die "$path: $!\n";
        print $fh $out;
        close $fh;
    }
}

if ($check)
{
    print "$count snippets, $stale stale\n";
    exit($stale == 0 ? 0 : 1);
}
print "$count snippets, $stale updated\n";

# Lines of $file from the line containing $from to the end of that declaration, or to the line containing $to.
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
            $code =~ s{`[^`]*`}{``}g;
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
