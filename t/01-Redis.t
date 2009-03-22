#!/usr/bin/perl

use warnings;
use strict;

use Test::More tests => 92;

use lib 'lib';

BEGIN {
	use_ok( 'Redis' );
}

ok( my $o = Redis->new(), 'new' );

ok( $o->ping, 'ping' );

diag "Commands operating on string values";

ok( $o->set( foo => 'bar' ), 'set foo => bar' );

eval { $o->set( foo => 'bar', 1 ) };
ok( $@, 'set foo => bar new again failed' );

cmp_ok( $o->get( 'foo' ), 'eq', 'bar', 'get foo = bar' );

ok( $o->set( foo => 'baz' ), 'set foo => baz' );

cmp_ok( $o->get( 'foo' ), 'eq', 'baz', 'get foo = baz' );

ok( $o->set( 'test-undef' => 42 ), 'set test-undef' );
ok( $o->set( 'test-undef' => undef ), 'set undef' );
ok( ! defined $o->get( 'test-undef' ), 'get undef' );
diag $o->exists( 'test-undef' );
ok( $o->exists( 'test-undef' ), 'exists undef' );

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

diag "Commands operating on lists";

my $list = 'test-list';

$o->del($list) && diag "cleanup $list from last run";

ok( $o->rpush( $list => "r$_" ), 'rpush' ) foreach ( 1 .. 3 );

ok( $o->lpush( $list => "l$_" ), 'lpush' ) foreach ( 1 .. 2 );

cmp_ok( $o->type($list), 'eq', 'list', 'type' );
cmp_ok( $o->llen($list), '==', 5, 'llen' );

is_deeply( [ $o->lrange( $list, 0, 1 ) ], [ 'l2', 'l1' ], 'lrange' );

ok( $o->ltrim( $list, 1, 2 ), 'ltrim' );
cmp_ok( $o->llen($list), '==', 2, 'llen after ltrim' );

cmp_ok( $o->lindex( $list, 0 ), 'eq', 'l1', 'lindex' );
cmp_ok( $o->lindex( $list, 1 ), 'eq', 'r1', 'lindex' );

ok( $o->lset( $list, 0, 'foo' ), 'lset' );
cmp_ok( $o->lindex( $list, 0 ), 'eq', 'foo', 'verified' );

ok( $o->lrem( $list, 1, 'foo' ), 'lrem' );
cmp_ok( $o->llen( $list ), '==', 1, 'llen after lrem' );

cmp_ok( $o->lpop( $list ), 'eq', 'r1', 'lpop' );

ok( ! $o->rpop( $list ), 'rpop' );


diag "Commands operating on sets";

my $set = 'test-set';
$o->del($set);

ok( $o->sadd( $set, 'foo' ), 'sadd' );
ok( ! $o->sadd( $set, 'foo' ), 'sadd' );
cmp_ok( $o->scard( $set ), '==', 1, 'scard' );
ok( $o->sismember( $set, 'foo' ), 'sismember' );

cmp_ok( $o->type( $set ), 'eq', 'set', 'type is set' );

ok( $o->srem( $set, 'foo' ), 'srem' );
ok( ! $o->srem( $set, 'foo' ), 'srem again' );
cmp_ok( $o->scard( $set ), '==', 0, 'scard' );

$o->sadd( 'test-set1', $_ ) foreach ( 'foo', 'bar', 'baz' );
$o->sadd( 'test-set2', $_ ) foreach ( 'foo', 'baz', 'xxx' );

my $inter = [ 'baz', 'foo' ];

is_deeply( [ $o->sinter( 'test-set1', 'test-set2' ) ], $inter, 'siter' );

ok( $o->sinterstore( 'test-set-inter', 'test-set1', 'test-set2' ), 'sinterstore' );

cmp_ok( $o->scard( 'test-set-inter' ), '==', $#$inter + 1, 'cardinality of intersection' );


diag "Multiple databases handling commands";

ok( $o->select( 1 ), 'select' );
ok( $o->select( 0 ), 'select' );

ok( $o->move( 'foo', 1 ), 'move' );
ok( ! $o->exists( 'foo' ), 'gone' );

ok( $o->select( 1 ), 'select' );
ok( $o->exists( 'foo' ), 'exists' );

diag "Connection handling";

ok( $o->quit, 'quit' );
