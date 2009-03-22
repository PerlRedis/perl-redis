#!/usr/bin/perl

use warnings;
use strict;

use Test::More tests => 7;
use lib 'lib';
use Data::Dump qw/dump/;

BEGIN {
	use_ok( 'Redis::Hash' );
}

my $h;

ok( my $o = tie( %$h, 'Redis::Hash', 'test-redis-hash' ), 'tie' );

isa_ok( $o, 'Redis::Hash' );

$h = {};

ok( ! %$h, 'empty' );

ok( $h = { 'foo' => 42, 'bar' => 1, 'baz' => 99 }, '=' );

is_deeply( $h, { bar => 1, baz => 99, foo => 42 }, 'values' );

is_deeply( [ keys %$h ], [ 'bar', 'baz', 'foo' ], 'keys' );

diag dump( $h );
