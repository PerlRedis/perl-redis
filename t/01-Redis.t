#!/usr/bin/perl

use warnings;
use strict;

use Test::More tests => 18;

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

foreach ( 0 .. 3 ) {
	ok(     $o->set( "key-$_" => $_ ),           "set key-$_" );
	cmp_ok( $o->get( "key-$_"       ), 'eq', $_, "get key-$_" );
}

ok( $o->quit, 'quit' );
