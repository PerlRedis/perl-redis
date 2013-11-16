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
$sock->send("$exp_cnt,$exp_len\n");
$exp_len += 1;

my $cnt = 0;
while (my $line = read_line($sock)) {
    my $len = length($line);
    print "LENGTH MISMATCH $len != $exp_len\n" if $len != $exp_len;
    ++$cnt;
}

printf "%.5f\n", (Time::HiRes::time() - $start_time);
print "CNT MISMATCH: $cnt != $exp_cnt\n" if $cnt != $exp_cnt;
exit 0;

# implementation of application layer buffering
# general concept:
# 1. try read 4K block of data
# 2. scan if for \n
# 3. if found, return line
# 4. go to step 1

my $str;
my $potential_data_in_str;
sub read_line {
    my $sock = shift; 

    if ($str && $potential_data_in_str) {
        my $idx = index($str, "\n");
        if ($idx >= 0) {
            return substr($str, 0, $idx + 1, '');
        }

        $potential_data_in_str = 0;
    }

    while (1) {
        my $buf;
        my $res = $sock->recv($buf, 4096);
        return unless defined $res;
        return unless $buf;

        my $idx = index($buf, "\n");
        if ($idx >= 0) {
            my $line = $str ? $str . substr($buf, 0, $idx + 1, '')
                            : substr($buf, 0, $idx + 1, '');

            $str = $buf;
            $potential_data_in_str = 1;
            return $line;
        } else {
            $str .= $buf;
        }
    }
}
