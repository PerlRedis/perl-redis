#!/usr/bin/perl

use warnings;
use strict;

use Test::More tests => 28;

use lib 'lib';

BEGIN {
	use_ok( 'Redis' );
}

ok( my $o = Redis->new(), 'new' );

ok( $o->ping, 'ping' );

ok( $o->set( foo => 'bar' ), 'set foo => bar' );

eval { $o->set( foo => 'bar', 1 ) };
ok( $@, 'set foo => bar new again failed' );

cmp_ok( $o->get( 'foo' ), 'eq', 'bar', 'get foo = bar' );

ok( $o->set( foo => 'baz' ), 'set foo => baz' );

cmp_ok( $o->get( 'foo' ), 'eq', 'baz', 'get foo = baz' );

ok( ! $o->get( 'non-existant' ), 'get non-existant' );

ok( $o->set('key-next' => 0), 'key-next = 0' );

my $key_next = 3;

foreach ( 0 .. $key_next ) {
	ok(     $o->set( "key-$_" => $_ ),           "set key-$_" );
	cmp_ok( $o->get( "key-$_"       ), 'eq', $_, "get key-$_" );
	cmp_ok( $o->incr( 'key-next' ), '==', $_ + 1, 'incr' );
}

cmp_ok( $o->get( 'key-next' ), '==', $key_next + 1, 'key-next' );

ok( $o->set('test-incrby', 0), 'test-incrby' );
foreach ( 1 .. 3 ) {
	cmp_ok( $o->incr('test-incrby', 3), '==', $_ * 3, 'incrby 3' );
}

ok( $o->quit, 'quit' );
