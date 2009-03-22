#!/usr/bin/perl

use warnings;
use strict;

use Test::More tests => 53;

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

my @keys;

foreach ( 0 .. $key_next ) {
	my $key = 'key-' . $_;
	push @keys, $key;
	ok(     $o->set( $key => $_ ),           "set $key" );
	ok(  $o->exists( $key       ),           "exists $key" );
	cmp_ok( $o->get( $key       ), 'eq', $_, "get $key" );
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

ok( $o->del( $_ ), "del $_" ) foreach map { "key-$_" } ( 'next', 'left' );
ok( ! $o->del('non-existing' ), 'del non-existing' );

cmp_ok( $o->type('foo'), 'eq', 'string', 'type' );

cmp_ok( $o->keys('key-*'), '==', $key_next + 1, 'key-*' );
is_deeply( [ $o->keys('key-*') ], [ @keys ], 'keys' );

ok( my $key = $o->randomkey, 'randomkey' );
diag "key: $key";

ok( $o->rename( 'test-incrby', 'test-renamed' ), 'rename' );
ok( $o->exists( 'test-renamed' ), 'exists test-renamed' );

eval { $o->rename( 'test-decrby', 'test-renamed', 1 ) };
ok( $@, 'rename to existing key' );

ok( my $nr_keys = $o->dbsize, 'dbsize' );
diag "dbsize: $nr_keys";

ok( $o->quit, 'quit' );
