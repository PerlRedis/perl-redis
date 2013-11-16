#!/usr/bin/perl

use strict;
use warnings;
use Time::HiRes;
use IO::Socket::INET;

my $exp_cnt = $ARGV[0];
my $exp_len = $ARGV[1];
my $start_time = Time::HiRes::time();

my $sock = IO::Socket::INET->new(
    PeerAddr => 'localhost',
    PeerPort => '1234',
    Proto     => 'tcp',
);

die $! unless $sock;
die $! unless print $sock "$exp_cnt,$exp_len\n";
$exp_len += 1;

my $cnt = 0;
while (my $line = <$sock>) {
    my $len = length($line);
    print "LENGTH MISMATCH $len != $exp_len\n" if $len != $exp_len;
    ++$cnt;
}

printf "%.5f\n", (Time::HiRes::time() - $start_time);
print "CNT MISMATCH: $cnt != $exp_cnt\n" if $cnt != $exp_cnt;
