#!/usr/bin/perl

use warnings;
use strict;

use Test::More tests => 93;

use lib 'lib';

BEGIN {
	use_ok( 'Redis' );
}

ok( my $o = Redis->new(), 'new' );

ok( $o->ping, 'ping' );

ok( $o->set( foo => 'bar' ), 'set foo' );
cmp_ok( $o->get( 'foo' ), 'eq', 'bar', 'get foo' );

ok( ! $o->get( 'non-existant' ), 'get non-existant' );

foreach ( 0 .. 42 ) {
	ok(     $o->set( "key-$_" => $_ ),           "set key-$_" );
	cmp_ok( $o->get( "key-$_"       ), 'eq', $_, "get key-$_" );
}

ok( $o->quit, 'quit' );
