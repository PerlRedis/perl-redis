#!/usr/bin/perl

use warnings;
use strict;

use Test::More tests => 43;

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

$o->del('non-existant');

ok( ! $o->exists( 'non-existant' ), 'exists non-existant' );
ok( ! $o->get( 'non-existant' ), 'get non-existant' );

ok( $o->set('key-next' => 0), 'key-next = 0' );

my $key_next = 3;

ok( $o->set('key-left' => $key_next), 'key-left' );

foreach ( 0 .. $key_next ) {
	ok(     $o->set( "key-$_" => $_ ),           "set key-$_" );
	ok(  $o->exists( "key-$_"       ),           "exists key-$_" );
	cmp_ok( $o->get( "key-$_"       ), 'eq', $_, "get key-$_" );
	cmp_ok( $o->incr( 'key-next' ), '==', $_ + 1, 'incr' );
	cmp_ok( $o->decr( 'key-left' ), '==', $key_next - $_ - 1, 'decr' );
}

cmp_ok( $o->get( 'key-next' ), '==', $key_next + 1, 'key-next' );

ok( $o->set('test-incrby', 0), 'test-incrby' );
ok( $o->set('test-decrby', 0), 'test-decry' );
foreach ( 1 .. 3 ) {
	cmp_ok( $o->incr('test-incrby', 3), '==', $_ * 3, 'incrby 3' );
	cmp_ok( $o->decr('test-decrby', 7), '==', -( $_ * 7 ), 'decrby 7' );
}

ok( $o->del('key-next' ), 'del' );

ok( $o->quit, 'quit' );
