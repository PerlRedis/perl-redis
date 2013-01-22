#!/usr/bin/perl
use warnings;
use strict;

use Redis;

my $pub = Redis->new();

my $channel = $ARGV[0] || die "usage: $0 channel\n";

print "#$channel > ";
while (<STDIN>) {
  chomp;
  $channel = $1 if s/\s*\#(\w+)\s*//;    # remove channel from message
  my $nr = $pub->publish($channel, $_);
  print "#$channel $nr> ";
}

