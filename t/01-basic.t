#!perl

use warnings;
use strict;
use Test::More;
use Test::Exception;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis();
END { $c->() if $c }


ok(my $o = Redis->new(server => $srv), 'connected to our test redis-server');
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
is_deeply([sort $o->keys('key-*')], [sort @keys], 'keys');

ok(my $key = $o->randomkey, 'randomkey');

ok($o->rename('test-incrby', 'test-renamed'), 'rename');
ok($o->exists('test-renamed'), 'exists test-renamed');

eval { $o->rename('test-decrby', 'test-renamed', 1) };
ok($@, 'rename to existing key');

ok(my $nr_keys = $o->dbsize, 'dbsize');

throws_ok sub { $o->lpush('foo', 'bar') },
  qr/\[lpush\] ERR Operation against a key holding the wrong kind of value,/,
  'Error responses throw exception';


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

$o->del($_) foreach qw( test-set1 test-set2 );
$o->sadd('test-set1', $_) foreach ('foo', 'bar', 'baz');
$o->sadd('test-set2', $_) foreach ('foo', 'baz', 'xxx');

my $inter = [sort('foo', 'baz')];

is_deeply([sort $o->sinter('test-set1', 'test-set2')], $inter, 'sinter');

ok($o->sinterstore('test-set-inter', 'test-set1', 'test-set2'),
  'sinterstore');

cmp_ok(
  $o->scard('test-set-inter'),
  '==',
  $#$inter + 1,
  'cardinality of intersection'
);

is_deeply([$o->sdiff('test-set1', 'test-set2')], ['bar'], 'sdiff');
ok($o->sdiffstore(qw( test-set-diff test-set1 test-set2 )), 'sdiffstore');
is($o->scard('test-set-diff'), 1, 'cardinality of diff');

my @union = sort qw( foo bar baz xxx );
is_deeply([sort $o->sunion(qw( test-set1 test-set2 ))], \@union, 'sunion');
ok($o->sunionstore(qw( test-set-union test-set1 test-set2 )), 'sunionstore');
is($o->scard('test-set-union'), scalar(@union), 'cardinality of union');

my $first_rand = $o->srandmember('test-set-union');
ok(defined $first_rand, 'srandmember result is defined');
ok(scalar grep { $_ eq $first_rand } @union, 'srandmember');
my $second_rand = $o->spop('test-set-union');
ok(defined $first_rand, 'spop result is defined');
ok(scalar grep { $_ eq $second_rand } @union, 'spop');
is($o->scard('test-set-union'), scalar(@union)-1, 'new cardinality of union');

$o->del('test_set3');
my @test_set3 = sort qw( foo bar baz );
$o->sadd('test-set3', $_) foreach @test_set3;
is_deeply([sort $o->smembers('test-set3')], \@test_set3, 'smembers');

$o->del('test-set4');
$o->smove(qw( test-set3 test-set4 ), $_) foreach @test_set3;
is($o->scard('test-set3'), 0, 'repeated smove depleted source');
is($o->scard('test-set4'), scalar(@test_set3), 'repeated smove populated destination');
is_deeply([sort $o->smembers('test-set4')], \@test_set3, 'smembers');


## Commands operating on zsets (sorted sets)
# TODO: ZUNIONSTORE, ZINTERSTORE, SORT, tests w/multiple values having the same score

my $zset = 'test-zset';
$o->del($zset);

ok($o->zadd($zset, 0, 'foo'));
ok(!$o->zadd($zset, 1, 'foo')); # 0 returned because foo is already in the set

is($o->zscore($zset, 'foo'), 1);

ok($o->zincrby($zset, 1, 'foo'));
is($o->zscore($zset, 'foo'), 2);

ok($o->zincrby($zset, 1, 'bar'));
is($o->zscore($zset, 'bar'), 1)
  ;    # bar was new, so its score got set to the increment

is($o->zrank($zset, 'bar'), 0);
is($o->zrank($zset, 'foo'), 1);

is($o->zrevrank($zset, 'bar'), 1);
is($o->zrevrank($zset, 'foo'), 0);

ok($o->zadd($zset, 2.1, 'baz'));    # we now have bar foo baz

is_deeply([$o->zrange($zset, 0, 1)], [qw/bar foo/]);
is_deeply([$o->zrevrange($zset, 0, 1)], [qw/baz foo/]);


my $withscores = {$o->zrevrange($zset, 0, 1, 'WITHSCORES')};

# this uglyness gets around floating point weirdness in the return (I.E. 2.1000000000000001);
my $rounded_withscores = {
  map { $_ => 0 + sprintf("%0.5f", $withscores->{$_}) }
    keys %$withscores
};

is_deeply($rounded_withscores, {baz => 2.1, foo => 2});

is_deeply([$o->zrangebyscore($zset, 2, 3)], [qw/foo baz/]);

is($o->zcount($zset, 2, 3), 2);

is($o->zcard($zset), 3);

ok($o->del($zset));    # cleanup

my $score = 0.1;
my @zkeys = (qw/foo bar baz qux quux quuux quuuux quuuuux/);

ok($o->zadd($zset, $score++, $_)) for @zkeys;
is_deeply([$o->zrangebyscore($zset, 0, 8)], \@zkeys);

is($o->zremrangebyrank($zset, 5, 8), 3);    # remove quux and up
is_deeply([$o->zrangebyscore($zset, 0, 8)], [@zkeys[0 .. 4]]);

is($o->zremrangebyscore($zset, 0, 2), 2);    # remove foo and bar
is_deeply([$o->zrangebyscore($zset, 0, 8)], [@zkeys[2 .. 4]]);

# only left with 3
is($o->zcard($zset), 3);

ok($o->del($zset));                          # cleanup


## Commands operating on hashes

my $hash = 'test-hash';
$o->del($hash);

ok($o->hset($hash, foo => 'bar'));
is($o->hget($hash, 'foo'), 'bar');
ok($o->hexists($hash, 'foo'));
ok($o->hdel($hash, 'foo'));
ok(!$o->hexists($hash, 'foo'));

ok($o->hincrby($hash, incrtest => 1));
is($o->hget($hash, 'incrtest'), 1);

is($o->hincrby($hash, incrtest => -1), 0);
is($o->hget($hash, 'incrtest'), 0);

ok($o->hdel($hash, 'incrtest'));    #cleanup

ok($o->hsetnx($hash, setnxtest => 'baz'));
ok(!$o->hsetnx($hash, setnxtest => 'baz'));    # already exists, 0 returned

ok($o->hdel($hash, 'setnxtest'));              #cleanup

ok($o->hmset($hash, foo => 1, bar => 2, baz => 3, qux => 4));

is_deeply([$o->hmget($hash, qw/foo bar baz/)], [1, 2, 3]);

is($o->hlen($hash), 4);

is_deeply([$o->hkeys($hash)], [qw/foo bar baz qux/]);
is_deeply([$o->hvals($hash)], [qw/1 2 3 4/]);
is_deeply({$o->hgetall($hash)}, {foo => 1, bar => 2, baz => 3, qux => 4});

ok($o->del($hash));                            # remove entire hash


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

ok($o->ping,  'ping() is true');
ok($o->quit,  'quit');
ok(!$o->quit,  'quit again, ok');
ok(!$o->ping, '... but after quit() returns false');

$o = Redis->new(server => $srv);
ok($o->shutdown(), 'shutdown() once is ok');
ok(!$o->shutdown(), '... twice also lives, but returns false');
ok(!$o->ping(), 'ping() will be false after shutdown()');

sleep(1);
throws_ok sub { Redis->new(server => $srv) },
  qr/Could not connect to Redis server at $srv/,
  'Failed connection throws exception';


## All done
done_testing();
