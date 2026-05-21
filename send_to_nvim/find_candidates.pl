#!/usr/bin/env perl
# find_candidates.pl - Combined path extraction and resolution in a single
# process. Replaces the pipeline of pick_raw_fragment -> extract_paths.sh ->
# parse_target -> resolve_path that previously spawned 3+ Perl interpreters.
#
# Usage: find_candidates.pl <raw_line> <mouse_x> <src_cwd> [repo_root]
#   Reads the joined tmux pane view on STDIN.
#   Outputs tab-separated: absolute_path\tline\tcol (one per candidate)
#
# Exit codes:
#   0 - one or more candidates found
#   1 - no path-like token at cursor position
#   2 - path looks valid but does not exist on disk (path printed to stderr)

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname basename);

my ($raw_line, $mouse_x, $src_cwd, $repo_root) = @ARGV;
$mouse_x  = int($mouse_x // 0);
$repo_root //= '';

sub looks_like_pathish {
    my ($token) = @_;
    return 0 if $token =~ m{://};
    my ($base) = split /:/, $token, 2;
    return 1 if $base =~ m{^/};
    return 1 if $base =~ m{^~/};
    return 1 if $base =~ m{^\.\.?/};
    return 1 if $base =~ m{/};
    return 1 if $base =~ m{^\.[A-Za-z0-9_-]+};
    return 1 if $base =~ m{\.[A-Za-z0-9_-]+$};
    return 1 if $base =~ m{^[A-Za-z0-9_-]+$};
    return 0;
}

sub clean_token {
    my ($t) = @_;
    $t =~ s/[.:]+$//;
    $t =~ s/:in$//;
    return $t;
}

sub parse_token {
    my ($raw) = @_;
    my $token = clean_token($raw);
    return () if $token eq '' || $token =~ m{://};

    if ($token =~ /^(.+?)(?::(\d+)(?::(\d+))?)?$/) {
        my ($path, $line, $col) = ($1, $2 // '', $3 // '');
        return () unless looks_like_pathish($path);
        return ($path, $line, $col);
    }
    return ();
}

sub resolve_file {
    my ($candidate) = @_;
    return undef unless -f $candidate;
    my $dir  = dirname($candidate);
    my $base = basename($candidate);
    my $real = abs_path($dir);
    return undef unless defined $real;
    return "$real/$base";
}

sub try_resolve {
    my ($path) = @_;

    if ($path =~ m{^~/}) {
        my $expanded = ($ENV{HOME} // '') . substr($path, 1);
        return resolve_file($expanded);
    }

    return resolve_file($path) if $path =~ m{^/};

    my $r = resolve_file("$src_cwd/$path");
    return $r if defined $r;

    if ($path =~ m{^[ab]/(.+)$}) {
        my $stripped = $1;
        $r = resolve_file("$src_cwd/$stripped");
        return $r if defined $r;
        if ($repo_root ne '') {
            $r = resolve_file("$repo_root/$stripped");
            return $r if defined $r;
        }
    }

    if ($repo_root ne '') {
        $r = resolve_file("$repo_root/$path");
        return $r if defined $r;

        my $repo_name = basename($repo_root);
        if ($path =~ m{^\Q$repo_name\E/(.+)$}) {
            $r = resolve_file("$repo_root/$1");
            return $r if defined $r;
        }
    }

    return undef;
}

# Step 1: Pick nearest path-like token from the raw terminal line.

$raw_line =~ s/\e\[[0-9;]*[A-Za-z]//g;

my @runs;
while ($raw_line =~ /([A-Za-z0-9._~\/:-]+)/g) {
    my $start = $-[0];
    my $end   = $+[0] - 1;
    my $token = clean_token($1);
    next if $token eq '';
    next unless looks_like_pathish($token);
    push @runs, [$token, $start, $end];
}

exit 1 unless @runs;

my @sorted_runs = sort {
    my $ad = ($mouse_x >= $a->[1] && $mouse_x <= $a->[2]) ? 0
        : ($mouse_x < $a->[1] ? $a->[1] - $mouse_x : $mouse_x - $a->[2]);
    my $bd = ($mouse_x >= $b->[1] && $mouse_x <= $b->[2]) ? 0
        : ($mouse_x < $b->[1] ? $b->[1] - $mouse_x : $mouse_x - $b->[2]);
    $ad <=> $bd || $a->[1] <=> $b->[1];
} @runs;

my $fragment = $sorted_runs[0]->[0];

# Step 2: Search joined view for matching lines, extract, and resolve.

my $extract_re = qr{
    (
        (?:
            ~/ | / | \.\.?/ |
            (?:[A-Za-z0-9._-]+/)+ |
            \.[A-Za-z0-9._-]+ |
            [A-Za-z0-9._-]+\.[A-Za-z0-9._-]+ |
            [A-Za-z0-9_-]+
        )
        [A-Za-z0-9._~/-]*
        (?: : \d+ (?: : \d+ )? )?
    )
}x;

my %seen;
my @results;

while (my $line = <STDIN>) {
    $line =~ s/\e\[[0-9;]*[A-Za-z]//g;
    next unless index($line, $fragment) >= 0;

    while ($line =~ /$extract_re/g) {
        my $raw_token = $1;
        next unless index($raw_token, $fragment) >= 0;

        my ($path, $line_no, $col_no) = parse_token($raw_token);
        next unless defined $path && $path ne '';

        my $resolved = try_resolve($path);
        next unless defined $resolved;

        my $key = $resolved;
        $key .= ":$line_no" if $line_no ne '';
        $key .= ":$col_no"  if $col_no  ne '';
        next if $seen{$key}++;

        push @results, [$resolved, $line_no, $col_no];
    }
}

# Step 3: Fallback - try the raw fragment directly.

unless (@results) {
    my ($path, $line_no, $col_no) = parse_token($fragment);
    if (defined $path && $path ne '') {
        my $resolved = try_resolve($path);
        if (defined $resolved) {
            push @results, [$resolved, $line_no, $col_no];
        } else {
            print STDERR "not_found\t$path\n";
            exit 2;
        }
    } else {
        exit 1;
    }
}

for my $r (@results) {
    print join("\t", @$r), "\n";
}
