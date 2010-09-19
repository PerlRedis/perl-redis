#!/usr/bin/perl

use warnings;
use strict;

use Test::More;
use Test::Exception;

BEGIN { use_ok('Redis') }

ok(my $o = Redis->new(), 'new with defaults');
ok($o->ping, 'ping');

ok($o = Redis->new(server => 'localhost:6379'), 'new with server');
ok($o->ping, 'ping');


## Commands operating on string values

ok($o->set(foo => 'bar'), 'set foo => bar');

ok(!$o->setnx(foo => 'bar'), 'setnx foo => bar fails');

cmp_ok($o->get('foo'), 'eq', 'bar', 'get foo = bar');

ok($o->set(foo => ''), 'set foo => ""');

cmp_ok($o->get('foo'), 'eq', '', 'get foo = ""');

ok($o->set(foo => 'baz'), 'set foo => baz');

cmp_ok($o->get('foo'), 'eq', 'baz', 'get foo = baz');

my $euro = "\x{20ac}";
ok($o->set(utf8 => $euro), 'set utf8');
cmp_ok($o->get('utf8'), 'eq', $euro, 'get utf8');

ok($o->set('test-undef' => 42), 'set test-undef');
ok($o->exists('test-undef'), 'exists undef');

# Big sized keys
for my $size (10_000, 100_000, 500_000, 1_000_000, 2_500_000) {
  my $v = 'a' x $size;
  ok($o->set('big_key', $v), "set with value size $size ok");
  is($o->get('big_key'), $v, "... and get was ok to");
}

$o->del('non-existant');
ok(!$o->exists('non-existant'),      'exists non-existant');
ok(!defined $o->get('non-existant'), 'get non-existant');

my $key_next = 3;
ok($o->set('key-next' => 0),         'key-next = 0');
ok($o->set('key-left' => $key_next), 'key-left');
is_deeply([$o->mget('foo', 'key-next', 'key-left')], ['baz', 0, 3], 'mget');

my @keys;
foreach my $id (0 .. $key_next) {
  my $key = 'key-' . $id;
  push @keys, $key;
  ok($o->set($key => $id), "set $key");
  ok($o->exists($key), "exists $key");
  is($o->get($key), $id, "get $key");
  cmp_ok($o->incr('key-next'), '==', $id + 1,             'incr');
  cmp_ok($o->decr('key-left'), '==', $key_next - $id - 1, 'decr');
}
is($o->get('key-next'), $key_next + 1, 'key-next');

ok($o->set('test-incrby', 0), 'test-incrby');
ok($o->set('test-decrby', 0), 'test-decry');
foreach (1 .. 3) {
  is($o->incrby('test-incrby', 3), $_ * 3, 'incrby 3');
  is($o->decrby('test-decrby', 7), -($_ * 7), 'decrby 7');
}

ok($o->del($_), "del $_") foreach map {"key-$_"} ('next', 'left');
ok(!$o->del('non-existing'), 'del non-existing');

cmp_ok($o->type('foo'), 'eq', 'string', 'type');

is($o->keys('key-*'), $key_next + 1, 'key-*');
is_deeply([$o->keys('key-*')], [@keys], 'keys');

ok(my $key = $o->randomkey, 'randomkey');

ok($o->rename('test-incrby', 'test-renamed'), 'rename');
ok($o->exists('test-renamed'), 'exists test-renamed');

eval { $o->rename('test-decrby', 'test-renamed', 1) };
ok($@, 'rename to existing key');

ok(my $nr_keys = $o->dbsize, 'dbsize');


## Commands operating on lists

my $list = 'test-list';

$o->del($list);

ok($o->rpush($list => "r$_"), 'rpush') foreach (1 .. 3);

ok($o->lpush($list => "l$_"), 'lpush') foreach (1 .. 2);

cmp_ok($o->type($list), 'eq', 'list', 'type');
cmp_ok($o->llen($list), '==', 5,      'llen');

is_deeply([$o->lrange($list, 0, 1)], ['l2', 'l1'], 'lrange');

ok($o->ltrim($list, 1, 2), 'ltrim');
cmp_ok($o->llen($list), '==', 2, 'llen after ltrim');

cmp_ok($o->lindex($list, 0), 'eq', 'l1', 'lindex');
cmp_ok($o->lindex($list, 1), 'eq', 'r1', 'lindex');

ok($o->lset($list, 0, 'foo'), 'lset');
cmp_ok($o->lindex($list, 0), 'eq', 'foo', 'verified');

ok($o->lrem($list, 1, 'foo'), 'lrem');
cmp_ok($o->llen($list), '==', 1, 'llen after lrem');

cmp_ok($o->lpop($list), 'eq', 'r1', 'lpop');

ok(!$o->rpop($list), 'rpop');


## Commands operating on sets

my $set = 'test-set';
$o->del($set);

ok($o->sadd($set, 'foo'), 'sadd');
ok(!$o->sadd($set, 'foo'), 'sadd');
cmp_ok($o->scard($set), '==', 1, 'scard');
ok($o->sismember($set, 'foo'), 'sismember');

cmp_ok($o->type($set), 'eq', 'set', 'type is set');

ok($o->srem($set, 'foo'), 'srem');
ok(!$o->srem($set, 'foo'), 'srem again');
cmp_ok($o->scard($set), '==', 0, 'scard');

$o->sadd('test-set1', $_) foreach ('foo', 'bar', 'baz');
$o->sadd('test-set2', $_) foreach ('foo', 'baz', 'xxx');

my $inter = ['foo', 'baz'];

is_deeply([$o->sinter('test-set1', 'test-set2')], $inter, 'siter');

ok($o->sinterstore('test-set-inter', 'test-set1', 'test-set2'),
  'sinterstore');

cmp_ok(
  $o->scard('test-set-inter'),
  '==',
  $#$inter + 1,
  'cardinality of intersection'
);


## Commands operating on hashes

my $hash = 'test-hash';
$o->del($hash);

ok($o->hset($hash, 'foo', 'bar'));
is($o->hget($hash, 'foo'), 'bar');


## Multiple databases handling commands

ok($o->select(1), 'select');
ok($o->select(0), 'select');

ok($o->move('foo', 1), 'move');
ok(!$o->exists('foo'), 'gone');

ok($o->select(1),     'select');
ok($o->exists('foo'), 'exists');

ok($o->flushdb, 'flushdb');
cmp_ok($o->dbsize, '==', 0, 'empty');


## Sorting

ok($o->lpush('test-sort', $_), "put $_") foreach (1 .. 4);
cmp_ok($o->llen('test-sort'), '==', 4, 'llen');

is_deeply([$o->sort('test-sort')], [1, 2, 3, 4], 'sort');
is_deeply([$o->sort('test-sort', 'DESC')], [4, 3, 2, 1], 'sort DESC');


## "Persistence control commands"

ok($o->save,     'save');
ok($o->bgsave,   'bgsave');
ok($o->lastsave, 'lastsave');

#ok( $o->shutdown, 'shutdown' );


## Remote server control commands

ok(my $info = $o->info, 'info');
isa_ok($info, 'HASH');


## Connection handling

ok($o->quit, 'quit');

throws_ok sub { Redis->new(server => '127.0.0.1:1') },
  qr/Could not connect to Redis server at 127[.]0[.]0[.]1:1:/,
  'Failed connection throws exception';


## All done
done_testing();
