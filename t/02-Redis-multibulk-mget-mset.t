#!/usr/bin/perl

use warnings;
use strict;

use Test::More tests => 5;

use lib 'lib';

BEGIN {
	use_ok( 'Redis' );
}

ok( my $o = Redis->new(), 'new' );

ok( $o->ping, 'ping' );

ok( $o = Redis->new( server => 'localhost:6379' ), 'new with server' );

diag "Multi-bulk mget and mset commands";

my $l = 5;

my @k = map { "key $_" } 1..$l;
my @v = map { "value $_" } 1..$l;

my @kv = map { $k[$_], $v[$_] } 0..$l-1;

$o->mset(@kv);
my @got_v = $o->mget(@k);

ok( eq_array(\@got_v, \@v), "mgot $l values: " . join(', ', @got_v) );
