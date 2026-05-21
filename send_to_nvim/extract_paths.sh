#!/usr/bin/env sh
set -eu

fragment=""
if [ "${1:-}" = "--fragment" ]; then
  fragment="${2:-}"
  shift 2
fi

perl -e '
  use strict;
  use warnings;

  my $fragment = shift @ARGV // q{};

  # Strip ANSI escape sequences from the fragment for matching
  $fragment =~ s/\e\[[0-9;]*[A-Za-z]//g;
  sub looks_like_path {
    my ($token) = @_;
    my ($base) = split /:/, $token, 2;

    return 0 if $base =~ m{://};        # reject URLs
    return 1 if $base =~ m{^/};
    return 1 if $base =~ m{^~/};
    return 1 if $base =~ m{^\.\.?/};
    return 1 if $base =~ m{/};
    return 1 if $base =~ m{^\.[A-Za-z0-9_-]+};
    return 1 if $base =~ m{\.[A-Za-z0-9_-]+$};
    return 1 if $base =~ m{^[A-Za-z0-9_-]+$};
    return 0;
  }

  my $pattern = qr{
    (
      (?:
        ~/ |
        / |
        \.\.?/ |
        (?:[A-Za-z0-9._-]+/)+ |
        \.[A-Za-z0-9._-]+ |
        [A-Za-z0-9._-]+\.[A-Za-z0-9._-]+ |
        [A-Za-z0-9_-]+
      )
      [A-Za-z0-9._~/-]*
      (?: : \d+ (?: : \d+ )? )?
    )
  }x;

  while (my $line = <STDIN>) {
    # Strip ANSI escape sequences
    $line =~ s/\e\[[0-9;]*[A-Za-z]//g;
    while ($line =~ /$pattern/g) {
      my $token = $1;
      # Strip trailing punctuation and Ruby :in suffix
      $token =~ s/[.:]+$//;
      $token =~ s/:in$//;
      next if $token eq q{};
      next if $fragment ne q{} && index($token, $fragment) < 0;
      next unless looks_like_path($token);
      print $token, "\n";
    }
  }
' "$fragment"
